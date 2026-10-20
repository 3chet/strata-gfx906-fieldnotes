# What NOT to tune — the rejections, with their counter-evidence

A negative result with evidence is worth more than a positive one with luck. Each entry here cost real
measurement time, and each could cost you the same if you repeat it.

---

## 1. `--lookup-chain 3` — rejected

**What the help says it does:** after the MTP's drafts, add up to K prompt-lookup drafts that continue
them; the window grows to at most 8.

**Why 3 and not 1 or 2:** `--spec 4` is already grown to 6 by `--suffix-draft` (default 3). K=0/1/2
leaves it at 6 — no change at all. K=3 → 7, K≥4 → 8. **Only K≥3 tests anything.**

**Measured (8 arms, palindromic, 8 measured samples per arm per workload):**

| workload | effect c | resolution 2·SE | verdict |
|---|---:|---:|---|
| count | −0.18 tok/s | ±1.33 | inside |
| echo | −0.39 tok/s | ±1.76 | inside |
| prose | +0.08 tok/s | ±0.44 | inside |

Signs disagree; nothing beats its own resolution.

**But the interesting part is the mechanism, not the null.** The flag *did* engage:

| workload | drafts/request (off → on) | acceptance (off → on) |
|---|---|---|
| count | 84.0 → 83.5 | 92.31% → 91.59% |
| echo | 142.5 → 143.0 | 90.52% → 90.07% |
| **prose** | **103.0 → 106.5** | **82.06% → 79.58%** |

On prose it added 3.5 draft checks per request and bought **+0.08 tok/s**. The extra drafts were
rejected. On `echo` — the *best case* for a lookup drafter, since the answer is a repeat of the prompt —
it added only 0.5 drafts, which says the lookup win is **already taken by the default `--suffix-draft 3`**.

*(Honest caveat: K=3 also raises the effective spec 6→7, so this was not strictly single-variable.)*

---

## 2. `--suffix-draft 0` — rejected (the default is doing work)

Hypothesis: at 88.9% acceptance the lookup drafter might be near-useless, and turning it off would save
the verification overhead.

**Measured (2×2 factorial, `--mtp-q4` as the second factor):**

| workload | effect | noise floor | verdict |
|---|---:|---:|---|
| **echo** | **−3.77 tok/s (−6.7%)** | 3.88% | **slower, 1.7× the floor** |
| count | −1.17 (−2.2%) | 2.00% | on the line — not claimed |
| prose | +0.18 (+0.4%) | 5.18% | no resolution |

Mechanism: on echo, turning lookup drafts off *raised* drafts/request (141 → 144) while acceptance
fell 90.05% → 85.19%. **The default of 3 is doing real work. Leave it.**

---

## 3. `--mtp-q4 all` — rejected, and the premise was backwards

**What the docs suggest:** the draft layer holds 912 MiB; 4-bit copies could save ~637 expert slots.
Classified as "a VRAM trade, not a pure gain".

**What actually happens** (startup lines, verbatim):

```
# baseline
strata mtp: draft layer loaded, 912 MiB of VRAM (experts 675, dense 111)

# --mtp-q4 all
strata mtp: --mtp-q4: 10 projections as Q4_0 (37.3 MiB)
strata mtp: draft layer loaded, 949 MiB of VRAM (experts 675, dense 111)
```

**912 → 949 MiB: it grows by 37.3 MiB**, exactly the size of the Q4 copies. `experts 675, dense 111` is
unchanged on both lines — **the Q4 weights are loaded in addition to the BF16 ones, not instead of
them.**

Expert cache slots confirm it: CUDA0 identical (6801 both), CUDA1 5019 → 4999 — a 20-slot loss matching
the 37 MiB.

Throughput: echo +1.4% (inside noise), count −2.1%, prose no resolution. **Strictly worse.**

> This is the single most valuable rejection in the repository: a documented "VRAM trade" that is
> actually a VRAM **cost**. Check the loader, not the help text.

---

## 4. `--prefill-head-alias` — unavailable on this configuration

Upstream has a good doc and a strong measured table (8 GB card, 185 → 667 tok/s as the chunk grows to
2048). The mechanism is attractive: unload the output head while a prompt is read, lend its VRAM to the
prompt buffers.

**Two independent reasons it does not apply here.**

**(a) The source refuses it.** Startup checks, in order:

```cpp
const char* why = !o.serve                     ? "it needs --serve"
                : multi_gpu || !stages.empty() ? "it supports one GPU only"
                : o.batch > 0                  ? "it does not support --batch"
                : o.pipeline_windows > 0       ? "it does not support --pipeline-windows"
                : o.short_read > 0             ? "it needs --short-read 0"
                : ...;
if (why != nullptr) { fprintf(stderr, "... unavailable: %s\n", why); return 2; }
```

This box violates **two**: the 2-GPU layer split, and `short_read` at its default 64. (It used to
violate three — `--batch 2` was the third, and it is gone now; see
[07 §C5](07-corrections.md#c5-head-alias-has-two-disqualifiers-now).) Any one alone
refuses startup, and `it supports one GPU only` is the message you will get.

**(b) The premise does not transfer.** The upstream gain comes from an 8 GB card where the chunk was
strangled to 256–768 tokens by VRAM pressure, so borrowing the head's memory made the chunk much bigger.
Here the chunk is already **16384** — there is nothing to grow.

---

## 5. `--pool-workers` — physically no headroom

Reasoning for trying it: prefill routes far more experts than decode, and GPU-cache misses are computed
by the CPU pool, so pool size should matter for prefill.

The engine's own startup lines:

```
strata generate: 5 expert-pool workers + the host thread
strata generate: 5 pool workers on logical processors 1,2,3,4,5, the host thread on 0 (draining too)
strata generate: pool is six threads on six cores instead of five plus an idle core
```

Ryzen 5 2600 = **6 physical cores / 12 threads**. `--pool-workers 0` ("all physical cores minus the
host's") resolves to **5** — identical to the current value. Going up uses SMT siblings, which for
AVX2-heavy expert GEMV usually *loses*. Going down obviously loses. **All six physical cores are
already busy.**

Note also: `--pool-workers` has **never varied** in 416 logged samples, so history cannot evaluate it —
this one needs a real arm, and the physics says do not bother.

---

## 6. `--prefill` chunk above 16384 — rejected, and the first evidence for it was an artefact

**A real trap, in two layers.**

Splitting the log by resolved chunk size looked like a clean natural experiment:

| chunk | n | median prefill tok/s |
|---|---:|---:|
| 8192 | 168 | 473 |
| **16384** | 242 | **493 (+4.2%)** |
| 15872 | 6 | 437 |

And by prompt-length band it looked even better: 16K–32K showed **+17.2%**.

**Both readings are wrong.**

1. **Composition (Simpson's paradox).** The two groups have different prompt-length mixes — the 10–12K
   warm-up fixture is 32% of the 8192 group and **50%** of the 16384 group. Short prompts score higher.
   Compare like with like and it evaporates:

   | prompt length | chunk 8192 | chunk 16384 | diff |
   |---|---:|---:|---:|
   | 10,764 | 428 | 415 | **−3.2%** |
   | 15,506 | 550 | 554 | +0.9% |
   | 7,403 | 475 | 485 | +1.9% |

2. **Time confound.** The 8192 epochs are 2026-10-13/14; the 16384 epochs are 2026-10-15 onward. Any
   per-epoch difference mixes chunk size with two days of build/profile/host changes.

**Then I repeated the same mistake in the other direction.** Having correctly thrown out the observational
evidence, I wrote a *cost* argument ("double prompt buffers") that I had never measured. That argument is
also wrong, and the real one is measurable. A controlled A/B on a fixed 32,209-token fixture, ring 384,
n=7 per arm:

| `--prefill` | **resolved** chunk | median | mean ± sd | span |
|---|---:|---:|---:|---:|
| `auto:16384` | 16384 | **689.1** | 685.0 ± 7.7 | 20.6 |
| `auto:12288` | **8192** | 690.2 | 689.6 ± 6.5 | 19.3 |
| `auto:32768` | **20992** | **521.4** | 510.8 ± 75.0 | **177.9** |

`8192 vs 16384`: +0.7%, t = 1.21 — no difference. `20992 vs 16384`: **−25.4%, t = −6.11**, spread
tripled. The cause is the ring's coverage boundary, not buffer memory: a 16384 chunk touches ≈384
distinct experts per layer, which fills a 384-slot ring exactly; 20992 needs ≈491, so layers get moved
twice ([08 §2](08-prefill-rings-and-chunks.md#2-the-chunk-and-the-ring-are-a-matched-pair)).

And the ladder is not the one I wrote down:

| you type | you get |
|---|---:|
| `auto:32768` | **20992** |
| `auto:16384` | 16384 |
| `auto:12288` | **8192** |

**Keep `--prefill auto:16384`** — but because 16384 × 384 is a matched pair, not because of buffer cost.

---

## 7. `--batch` above 1 — rejected, including the 2 I was running

`--batch` only helps while two requests are in flight. Before spending VRAM, measure the overlap.

Detection: `strata batch: slot N takes …` opens a slot, `… gave back …` closes it. Two open = overlap.

| production epoch | requests | moments with 2 slots held | share | peak |
|---|---:|---:|---:|---:|
| A | 585 | 8 | 1.4% | **2** |
| B | 935 | 1 | 0.1% | **2** |

Peak concurrency never reached 3, and the engine was idle 67–88% of wall time. Cost of batch 3, measured:

```
128K saves:    (0.63-0.52)*2 + (0.87-0.71)*2 = 0.54 GiB
batch3 costs:  0.52*1 + 0.71*1               = 1.23 GiB
net:                                          +0.69 GiB  →  −123 expert slots
```

Each `--batch` slot is a **full session** (whole K/V + buffers), not a share of spare room. Batch 3 costs
more than the 128K change frees.

**The correction: this argument was always about `--batch 2` too.** A 1.4% and a 0.1% overlap rate is
not a reason to keep a slot that costs 13–16% of the expert cache. I used the measurement only to reject
the value I was not running. Deleting the flag entirely:

| | `--batch 2` | `parallel: 1` |
|---|---:|---:|
| expert slots | 11,897 | **13,529–13,767** |
| expert cache | 18.8 GiB | **21.2–21.6 GiB** |
| decode, single request | within noise | within noise |
| a second request at the same time | served together | **waits ~6.0 s** |

That trade is right for one serial session and wrong for two. Measure, then choose — but the default on a
single-session box is **1**, and it is the faster of the two.

---

## 8. Filling the rocBLAS table — the `default` rows are a verdict, not blanks

The tuning table has rows whose first column literally reads `default`. Those are **the calibrator's
conclusion** — `tune_rocblas.cpp` marks a shape `default` when no candidate beat the built-in kernel by
`--min-gain 1.05` (5%). They are not rows waiting to be filled in.

On this box `fallbacks=0` — nothing to repair. Upstream's "+31.9%" comes from another GPU; on gfx906 the
net gain decays with T (43.5% at T≤1024 → 3.8% at the 8192 bucket). **Closed.**

---

## 9. Per-layer expert cache — the help criticises a default we are not on

`--expert-cache-per-layer`'s help describes the "slots handed out in arrival order" failure. This box
runs **PROFILE** residency (119/119 starts), which is the cure, not the disease. Additionally, the
per-layer sizing path changes the *total* slot count (`slots = q * 48`), so it cannot be compared as a
pure strategy change — and upstream records it as `decoded 21% slower`. **Closed.**

---

## 10. `--pipeline-windows 2` — rejected, and it had never actually run

Full data in [`09 §1`](09-concurrency.md#1---pipeline-windows-2--rejected-and-the-flag-had-never-been-on).
The two-line version:

| arm | prefill 8.3K | spread | decode |
|---|---:|---:|---:|
| no pipeline | **491.7** | 1.4% | 42.0–44.3 |
| pipeline 2 | **361.0** | **190%** | 42.8 |
| pipeline 2 + draft moved to card 0 | 443.1 | 3.5% | 40.8 |

**−26.6% prefill for a decode gain inside noise.** The upstream +21% is gfx12 data.

And the part worth remembering: `--batch` was resetting `pipeline_windows` to 0 inside the engine, with
**no log line on the auto path**. Every earlier "no effect" reading of this flag was measuring the
default. See [02 §4.5](02-methodology.md#45-a-flag-you-set-can-be-reset-by-a-flag-you-did-not).

## 11. `--kv-grow` — unavailable, and it is one line of source

```cpp
if (o.kv_grow) {                       // generate.cpp:4397
    if (multi_gpu) { /* not supported */ }
}
```

A layer split sets `multi_gpu`. Dead on this box, and no flag combination fixes it. **Do not investigate
further.**

## 12. `--calibrate` — it does not measure what you want

The autotuner covers `pcie_frac`, `spec_min_p`, `pool_workers` and `adapt`. Three of those are already
settled by direct A/B here, and the fourth (`adapt`) is not the bottleneck. It **does not touch the
prefill pipe**, which is where the remaining headroom is.

Worse, running it would *change* settings you have already decided, with its own noise floor. Treat
`--calibrate` as a starting-point generator, not a judge.

## 13. `STRATA_EMB_REUSE_ACCOUNT=1` — no mechanism on this config

Upstream reports +3.9% on IQ3_XXS. Here it cannot produce any observable change, and that is checkable
in source rather than measurable:

```cpp
// prefill.cpp:1904
if (!emb_reuse_account()) f(T * N);      // the planner counts T*(D-HC)*4 bytes for the buffer
```

The flag tells the planner that one buffer is aliased, which frees room for **① a bigger chunk, ② more
ring slots**. On this box:

- ① is pinned by `--prefill auto:16384`, and the next rung up (20992) is the −25% arm;
- ② is pinned by `STRATA_PREFILL_RING=384`, which sits *above* the byte-budget path in
  `ring_slots()` — and 512 is measurably worse.

Both outlets are closed. This is **"no mechanism", not "tried and failed"** — worth distinguishing,
because a negative measurement would have implied the gain exists but is outweighed.

## 14. `STRATA_PREFILL_CPU_SHARE` — only effective on small chunks

It shifts expert-compute work to the CPU during prefill, which helps when the chunk is ≤3K tokens and the
GPU is the bottleneck. At 16384 it does nothing measurable. If you are running a small chunk on a
many-core CPU, revisit it; here it is closed.

---

## 15. `--kv-resident` — rejected, measured at a net loss

`--kv-resident N` keeps the most recent `N` cells of KV per QSA layer in VRAM and streams the rest
from pinned host RAM, which frees VRAM for expert slots. The idea is sound and it is the only option
here that buys slots **without** shortening `--max-context`. It still loses.

N = 40960, one arm each, fresh restart per arm:

| | off | `--kv-resident 40960` |
|---|---:|---:|
| CUDA0 expert slots | 7,836 | **8,023** |
| CUDA1 expert slots | 5,931 | **6,276** |
| **total slots** | 13,767 | **14,299 (+3.9%)** |
| KV held in pinned RAM | — | 0.35 GiB |
| block reads served from VRAM | — | 97.61% of 3,180 |
| **decode, n=3 median** | **43.8 tok/s** | **40.8 tok/s (−6.9%)** |
| expert-cache hit rate | 0.99 | 0.99 |

**Verdict: +3.9% slots for −6.9% decode. Rejected, rolled back.**

The hit rate is the tell. It did not move, so this is not an expert-locality effect — the loss is
charged by the KV streaming itself. And note the awkward part: **97.61% of block reads already hit
VRAM** and it *still* costs 7%. What you pay for is the 2.4% that miss, once per layer per token, along
a path whose narrowest link is x4 (see [07 §G3](07-corrections.md#g3-metrics-spec-is-not-argv-spec) on
why the metrics report 4 while sysfs reports 16 — both are correct).

**The one thing worth keeping from this experiment** is that it is the only way to make the engine
state the KV's true size on the record. It did, and the number was 8× smaller than my estimate:
0.35 GiB for 40,960 of 163,840 cells ⇒ **≈0.47 GiB total**. That kills the whole "trade KV VRAM for
expert slots" line of thinking, including lowering `--max-context` — see
[11 §4](11-long-context-and-verify-timeout.md#4-the-kv-cache-is-047-gib-not-387-gib--and-lowering---max-context-buys-nothing).

---

## Summary: what to keep

If you are on gfx906 with a layer split, the configuration that survived all of this is:

```
--expert-cache auto
--prefill auto:16384              # do not move; 20992 resolves from 32768 and is −25%
--spec 4 --spec-min-p 0.7         # effective verify width is 6; /metrics reports 6, argv says 4
--mtp <your mtp dir>              # suffix-draft stays at its default 3
                                  # NO --batch; set "parallel": 1 in the model JSON
--max-context 163840              # with "fit_max_tokens": true
--kv q4_0
--layer-split auto
--pool-workers 5                  # = the default resolution on 6 physical cores
--pcie-frac 0.3
--vram-reserve-mib 1024           # engine's own safe floor is 512; 1536 is pure loss
--adapt-every 4 --expert-profile-save-every 3

env: STRATA_PREFILL_RING=384      # a layer split otherwise forces 96
```

In other words: **the defaults were already right** — *except* for the ring, which a layer split quietly
overrides. That is the one place where the default is not what a layer-split user gets. The value of the
exercise is knowing *which* defaults, and having the counter-evidence to stop yourself from "improving"
them later.

Two things to check on your own box before copying this, because they are the two most expensive mistakes
in the repository:

1. **`"parallel"` in the JSON, not `--batch` in `argv`.** The flag is injected by the server; removing it
   from the args array does nothing.
2. **What your context limit is actually doing for you.** On a box without `--batch`, raising it does not
   cost slots the way the old A/B suggested.
