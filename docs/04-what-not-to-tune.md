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

This box violates **three**: 2-GPU layer split, `--batch 2`, and `short_read` at its default 64. Any one
alone refuses startup.

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

## 6. `--prefill` chunk above 16384 — rejected on cost, and the "gain" was an artefact

**A real trap.** Splitting the log by resolved chunk size looked like a clean natural experiment:

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

Cost side: `auto:N` is clamped to **32768 / 16384 / 8192**. This build is already at 16384; going up
means double prompt buffers — the prompt path already borrows **6.38 GiB** of cache slots — to chase an
effect that disappears under control. **Keep 16384.**

---

## 7. `--batch 3` — rejected (production never overlaps enough)

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

## Summary: what to keep

If you are on gfx906 with a layer split, the configuration that survived all of this is:

```
--expert-cache auto
--prefill auto:16384
--spec 4 --spec-min-p 0.7
--mtp <your mtp dir>          # suffix-draft stays at its default 3
--batch 2
--max-context 131072
--kv q4_0
--layer-split auto
--pool-workers 5              # = the default resolution on 6 physical cores
```

In other words: **the defaults were already right.** The value of the exercise is knowing *which* ones,
and having the counter-evidence to stop yourself from "improving" them later.
