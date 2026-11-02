# Why decode stops at ~46: four explanations that do not survive, and the one that is left

> **Short version.** The paper number is 200 tok/s and the measured number is 43–48. Four plausible
> explanations for the gap were tested and all four were wrong — including the one this repository
> itself was most confident about, "overlap the CPU pool with the GPU", which turned out to be
> already implemented and worth **+6–7%**, not +18–27%. What is left is one bottleneck: **the CPU's
> share of the experts is exposed on the critical path, and it runs on six saturated Zen+ cores.**
>
> The figure this document used to lead with — *"kernel efficiency 24.5% of peak"* — is withdrawn in
> [§7](#7-the-cpu-share-measured--and-why-245-was-wrong): it divided an int8 measurement by an FP32
> peak. The absolute numbers survive and are what to quote: **1.27 ms per expert, 1.19 GB/s per core.**
>
> The instrument that settled it is `STRATA_DECODE_TIMING=1`, and the experiment is a single variable:
> make the CPU side 2.5× slower and see whether the window moves.

Measurement basis as in [`14`](14-host-side-switches.md): 0.1.55, IQ3_S, `parallel: 2`, 5 pool workers.

---

## 1. The gap, stated honestly

```
paper:  5.08 GB/token  ÷  1024 GB/s          =  200 tok/s
actual: 5.08 GB/token  ÷  23.3 ms (43 tok/s) =  218 GB/s effective
```

The 218 GB/s decomposes as `1024 × 0.5 × 0.43`. Both factors are inferences from measurement, not
independent readings, but each has direct support:

| factor | meaning | evidence |
|---|---|---|
| **× 0.5** | a layer split is a relay: at any instant one card's bandwidth is working, the other is waiting | 1,514 samples at 10 ms: **both cards above 50% in 12 samples = 0.8%** |
| **× 0.43** | a 1-token GEMV cannot fill the memory pipe | K = 2560 splits into 40 quantised blocks per row, M = 1 — there is not enough concurrent demand to saturate |

Two further readings point the same way: the memory controllers sit at **6.3% / 7.4%** during decode
(peak 36%), and the same silicon prefills at **820–865 tok/s** — 20× the decode rate. The hardware is
not being asked to move bytes faster; it is being asked to finish 720 tiny kernels per token
(48 layers × 15 GEMVs, 1,440 across two cards), i.e. **~32 µs per kernel** at 23 ms/token, most of
which is launch, sync and waiting on the previous layer's output.

That is the whole shape of the problem: **latency-bound, not bandwidth-bound.** Nothing below changes
it; what follows only removes the things that were believed to be worth 10–30% and are not.

## 2. "Overlap the CPU pool with the GPU" — already implemented, worth +6–7% not +18–27%

This is the correction this repository most needed, because the wrong version was published in a
private note and acted on.

**What the wrong reading said.** `verify.cpp` around the pool call reads: check the doorbell, compute
the CPU's share of the experts, *then* publish the flag. Sequential on its face, so the 4.5 ms of pool
time looked like 4.5 ms of GPU idle, and hiding it looked like +18–27%.

**What the code actually does.** The ordering that matters is one layer down, in the dispatch:

```cpp
// expert_source.cpp:3720
// ---- plan v0.3 P6: the GPU's share, decided and published FIRST
//      so the GPU starts while the CPU works.

:3849  if (P.publish) P.publish(P.ctx);        // ← flag A: the GPU starts here
:3870  // activation quantisation
:3968  d.pool->run_split_multi_native(...)     // ← the CPU's share, blocking
```

and the GPU side is symmetric:

```cpp
:1636  grouped(..., hit_out);              // the resident experts first
:1644  wait_flag_ge(m_flagB_, ring, cs);   // only then wait for the CPU's misses
```

So GPU-on-resident and CPU-on-miss already run concurrently. The published plan is 0.12 ms per window
(**0.3%** of it) — there is nothing left to "publish earlier".

**The measurement, and it is a one-variable experiment.** If the overlap is real, making the CPU share
2.5× slower must *not* move the window proportionally. Drop the pool from 5 workers to 2:

| arm | window | `plan` | `actq` | `jobs` | **`run`** (CPU share) | decode |
|---|---:|---:|---:|---:|---:|---:|
| workers = 5 | 38.3 / 41.8 / 41.7 ms | 0.12 | 0.07 | 0.01 | **3.45–5.18 ms** | 45.1 / 46.8 / 42.9 |
| workers = 2 | 44.4 / 42.5 ms | 0.14 | 0.06 | 0.01 | **6.43–6.62 ms** | 41.7 / 44.9 / 41.4 |

`run` went up ~1.8×; decode fell 7.5%. **The CPU share is exposed, roughly one-to-one — about 67% of
it lands on the critical path.**

**Ceiling, recomputed.** `run` is 9.2% of the window and 67% of it is exposed ⇒ hiding all of the CPU
work entirely buys **+6–7%** (45 → 48), not +18–27%.

**Why it cannot be hidden further, structurally.** The CPU cannot start before it knows which experts
missed, and that routing result is produced *by the GPU, inside the layer*. The only window the CPU can
use is "GPU computes the resident experts", which is the same order of magnitude as the CPU's own work.
Escaping it requires predicting the next layer's routing — the `lookahead` path, measured negative on
this box — or making the CPU share faster. Those are the same two options in §6.

## 3. "The GPU is running at low clocks" — true, and irrelevant

A reading nobody had taken: what the DPM governor does during decode. Sampled 110 times at 0.4 s
intervals while a 900-token request ran:

| | idle ceiling | during decode |
|---|---|---|
| `sclk` (compute) | 1700 MHz | **56% of samples at 860 MHz — the lowest state** |
| `mclk` (memory) | 1000 MHz | **43% of samples at 350 MHz — the lowest state** |

The governor classifies "small kernels, low occupancy" as a light load and does not upclock. Forcing
`power_dpm_force_performance_level = high` fixes it: `mclk` locks to 1000 MHz for the whole request and
high `sclk` states go from 21/110 to 61/110 samples — nearly 3×.

**Result: 46.75 → 46.10 tok/s. Unchanged.**

| arm | `mclk` | high-`sclk` samples | decode |
|---|---|---:|---:|
| `auto` | mostly 350 MHz | 21 / 110 | **46.75** |
| `high` (forced) | 1000 MHz locked | 61 / 110 | **46.10** |

This is a useful negative result in both directions:

- It closes clock and power as a tuning axis. The prefill numbers were already computed-bound; now
  decode is shown not to be clock-bound either.
- It **confirms** the §1 conclusion independently. If `wait` (71% of the window) were waiting on
  arithmetic or memory, tripling the high-clock residency would move it. It does not. What is left is
  launch and synchronisation latency, which does not care about frequency.

One loose end, deliberately left loose: `power1_cap` reads **190 W** against a 300 W board TDP, and
the driver refuses writes. Given the result above, that is not worth arguing with.

## 4. "Port a community gfx906 kernel" — the anchors do not exist, because the work is done

There is real gfx906 work upstream of this engine. Three patches from a public `mi50-qwen3.8-fast` fork
looked directly applicable: multi-column gated-delta-net, a few-rows F32 matvec path, and multi-column
MMVQ. All three were checked against this engine's source, read-only, by grepping their anchor lines.

| patch | anchors searched | hits | verdict |
|---|---|---:|---|
| `gdn-multicolumn` | `launch_gated_delta_net`, `case 128:` | **0** | **already built in** |
| `mmvf-few-rows` | `has_fusion`, `mul_mat_vec_f_switch_fusion`, `ncols_dst`, `ssm_alpha` | **0 / 0 / 0 / 0** | not applicable |
| `mmvq-q4_0-multicol` | `calc_nwarps`, `MMVQ_PARAMETERS_GCN`, `ncols_dst` | 0 by name | **already built in, stricter** |

"Already built in" is not a courtesy. The engine's own comments point at the code it replaced:

```cpp
// native_gdn.cu:119 — S/4 z-blocks, 4 columns per block, one warp per (head, col),
// its four rows held in registers
step<<<dim3(h_v, 1, S/4), dim3(32, 4)>>>(...);
```

The file's header states the difference from the upstream implementation explicitly: *"Arithmetic
adapted from gated_delta_net.cu … Only state addressing differs."* The community patch adds a 4-column
variant to llama.cpp; this engine's version is the same idea, more thorough, and it is **live in
production** (`--native`).

`native_mmvq.cu` is blunter still, at `:1153`: the upstream multi-column table is described as
*"faster, equal to ncols = 1 only to float rounding"* — and then rejected, because the MTP verify path
requires every column to be **bitwise** equal to a single-column call. The community patch modifies
exactly that table. There is nothing to port, because the code is no longer the same code.

**One genuine gap, and it is the wrong shape to exploit.** Neither `v_dot2`, `sdot4`, nor
`__builtin_amdgcn_sdot4` appears anywhere in the 6.4 MB of engine source — the GPU quantisation path
uses `__builtin_amdgcn_perm` plus scalar integer ops. The DOT instructions are gfx906's best
instruction-level asset and are unused.

They are also not free here: `sdot4` needs int8 operands, and this pack is 2-bit (IQ2_S gates/up,
Q2_0 down), so the sign-extension into int8 would likely cost more than the dot product saves. They pay
on **Q4_0**, which is a different trade — see §5.

A useful independent confirmation came out of the same search. The gfx906-turbo fork's own README says:

> *"gfx906 at batch = 1 is **latency-bound (10% bandwidth utilization), not bandwidth-bound**. Both this
> fork and vllm-gfx906 hit the same **~56 tok/s ceiling on MoE models**."*

That is §1, derived independently by people running four cards on 80B-class MoE. The 43–48 here is the
same regime.

## 5. Q4_0 and IQ4_XS — both closed, for different reasons

Higher bit-width is the intuitive answer to "the model is a bit dim", and both were costed rather than
guessed.

**IQ4_XS: measured, −14–18% decode.** Not a prediction — an A/B on this box. Under a latency-bound
regime, more bytes per expert is pure loss: the unpack instruction count does not drop (it is still an
i-quant codebook), the slot count falls, and the CPU's share of misses grows.

**Q4_0: costed, and it fails on three independent counts.**

| item | IQ3_S (current) | Q4_0 | consequence |
|---|---|---|---|
| blob per expert | 1.44 MiB | 2.64 MiB | **×1.83** |
| pack on disk | 48.5 GB | **~88.8 GB** | exceeds the ~67 GB page-cache budget of an 80 GB box by 22 GB |
| expert slots (23,183 MiB quota) | 11,958 | **~6,530** | **−45%** |
| coverage | 48.6% | 26.6% | hit rate 97.3% → **~94%** |
| `pool + plan` | 4.5 ms | ~10 ms | **−22%** on the window |
| cold-start warm-up | ~21 s | ~39 s | doubles after every restart |

Slot count is the part RAM cannot fix: **more RAM buys page cache, not VRAM.** At 6% miss,
48 layers × 10 experts × 2.64 MiB = ~76 MB/token, and once the pack no longer fits in page cache that
comes off NVMe rather than RAM. Expected decode: **25–32 tok/s**, prefill 500–600.

So Q4_0 is a quality trade — 4.5 vs 2.46 bits per weight, plausibly a perfect score on a 15-case
battery instead of 14/15 — paid for with decode, prefill, 40 GB of RAM and a kernel port. Declined, with
a reopening condition: **≥112 GB RAM** *and* a reason to prefer quality over throughput on this box.

## 6. What is actually left

One bottleneck, and after §7 only one way left to attack it. Everything here is the same `run`
component that §2 shows is 67% exposed.

| | gain | cost | status |
|---|---|---|---|
| **CPU with better single-core throughput** (same socket, 1 day) | **+15–18%, likely more** | one downtime window, fully reversible | **recommended** — the last two-digit move |
| **Hand-written AVX2 expert kernel** | **~0 headroom found** — see §7 | 2–3 weeks, x86 intrinsics, must pass the quality battery | **closed**, pending one measurement |
| Raise CPU clocks / core count on the current socket | 0 | — | 6 cores already fully occupied, 5 workers + host |
| Predict next-layer routing to widen the overlap window | negative | — | measured, `lookahead` |

The kernel project is closed on arithmetic, not pessimism. The CPU share is **7.1 ms of a 50.8 ms
window — 14.3%**. Make the kernel infinitely fast and the end-to-end gain is **+14%**; make it 1.6×
faster (the old plan, "24.5% → 40% of peak", a peak that was never 24.5%) and the gain is **~+3%**.
§7 then shows the kernel already sits on the best software path this ISA offers — multi-column dequant
sharing, gather guard, prefetch and the non-VNNI two-step are all present and live.

What is *not* closed is one unexplained gap: **1.19 GB/s per core measured**, against the
**~5 GB/s per core** the source's own comment quotes for the IQ family. If that 4× is real and not a
different-ISA artifact, the kernel story reopens — at a different order of magnitude. §7 names the
single measurement that decides it.

One caution on the CPU upgrade row, from the same analysis: Zen+ **splits every 256-bit integer op into
two 128-bit µops** and has no AVX-VNNI. Zen3 does neither, and drops from two CCX to one 32 MB L3. On
an int8 dot path that is a 2–2.5× class change, not the 19% the IPC number implies — so **+15–18% is
more likely a floor than a midpoint.**

Raw aggregates: [`results/r36-pool-exposure.csv`](../results/r36-pool-exposure.csv),
[`results/r37-gpu-clock.csv`](../results/r37-gpu-clock.csv).

## 7. The CPU share, measured — and why 24.5% was wrong

Everything below comes out of the instrument, not a benchmark harness. Twenty `decode timing` lines had
accumulated on the live process over 51 minutes of ordinary traffic; the last six:

| window tokens | window ms | CPU ms | CPU experts / layer / window | VRAM hits / layer / window | hit rate |
|---:|---:|---:|---:|---:|---:|
| 1.96 | 50.81 | 7.27 | 0.59 | 22.66 | 97.5% |
| 1.73 | 45.26 | 8.29 | 0.67 | 18.70 | 96.5% |
| 1.78 | 44.82 | 8.00 | 0.64 | 19.36 | 96.8% |
| 1.78 | 42.69 | 6.58 | 0.53 | 19.32 | 97.3% |
| 2.00 | 44.41 | 6.43 | 0.52 | 22.40 | 97.7% |
| 1.76 | 42.52 | 6.62 | 0.54 | 19.49 | 97.3% |

Chaining the columns gives the per-expert cost with no extra instrumentation:

```
0.58 experts/layer/window × 48 layers   ≈ 28 experts per window
28 ÷ 5 workers                         ≈ 5.6 experts per worker
7.1 ms ÷ 5.6                           ≈ 1.27 ms per expert
9.8 MFLOP × 2 tokens ÷ 1.27 ms         ≈ 15 GFLOPS per core
1.51 MB ÷ 1.27 ms                      ≈ 1.19 GB/s per core
```

**The withdrawn number.** "24.5% of peak" divided 14.4 GFLOPS by **58.7** — the Zen+ *FP32 FMA* peak,
3.668 GHz × 16 FLOP/cycle. But the path being measured is an **int8 dot product**: one 256-bit AVX2
instruction carries 32 int8 lanes, so the int8 ceiling on the same silicon is roughly twice the FP32
one (~118 GOPS). Dividing an int8 throughput by an FP32 peak is a units error, and it inflated the
apparent headroom by about 2×. Correctly stated the figure is **~12%** — still low, but the direction of
the mistake matters: **it made a closed project look like a 1.6× opportunity.**

The absolute numbers are the durable part. They do not depend on a peak.

**The kernel is already where a kernel can reach on this ISA.** Six checks against the source:

| check | result |
|---|---|
| IQ2_S (type 18) has a multi-column AVX2 kernel | yes — `iq256_gu_rows`, type 22 in the support table |
| Q2_0 (type 42) has one | yes — `q2_rows_any` → `q2_0_gguf_rows_multi_avx2` |
| fallback without AVX-512 | correct, gated at `cpu_avx512_ok()` |
| fallback without AVX-VNNI | correct, `maddubs` + `madd` two-step (`iq_avx2.cpp:19` states VNNI is a separate copy) |
| gather fast path | correctly refused on AMD — `cpu_gather_fast()` tests for `GenuineIntel` first, so this is a designed fallback, not a mis-detection |
| prefetch | present, `iq_avx2.cpp:193-194` |

Which leaves three ceilings, none of them in the code:

1. **No AVX-512 on Zen+** — every 256-bit integer op is split into two 128-bit µops, halving front-end throughput.
2. **No AVX-VNNI on Zen+** — an int8 dot product costs `vpmaddubsw` + `vpmaddwd` where one `vpdpbusd` would do.
3. **IQ2_S is a codebook format** — one grid lookup per 32 weights, and the source comment puts the practical ceiling near `~5 GB/s per core`.

**The gap that is still open.** 1.19 GB/s measured against ~5 GB/s quoted. ISA differences plausibly
explain 2× of a 4× gap. Three candidates, none tested:

- the ~5 GB/s figure may come from an AVX-512 machine at `nt ≥ 3` — the comment originates on a 14900KF;
- the prefetch distance may be too short for IQ2_S's 10-byte blocks — 128 B of lookahead covers only ~12 of them;
- cross-CCX traffic: workers land on cores 1–5, and **cores 3–5 sit in CCX1 while 0–2 sit in CCX0**, so shared weights cross Infinity Fabric.

**What decides it.** A CPU-only bench of IQ2_S/Q2_0 at real byte rates on this box — `kq_cpu_bench
--pairs iq2_s/q2_0` in the build tree is the intended entry point, run single-threaded against a live
process that is not decoding. Until that number exists the kernel project stays closed: the software
path is exhausted, and the remaining ceiling is the instruction set, not the intrinsics.
