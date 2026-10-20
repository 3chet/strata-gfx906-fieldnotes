# Strata on 2× Radeon Pro VII (gfx906): field notes

**English** · [简体中文](README.zh-CN.md)

**This is not an installation guide.** The Strata project already has one, and it is good:
[docs/INSTALL.md](https://github.com/Niko1221/Strata/blob/main/docs/INSTALL.md) and
[docs/OLDER_GPUS.md](https://github.com/Niko1221/Strata/blob/main/docs/OLDER_GPUS.md) cover the gfx906 build
(`-DSTRATA_HIP_GFX906=ON`) better than I could.

This repository is the part that is **missing** from those docs: what happens *after* it runs —
**how to measure it without fooling yourself, and which knobs to leave alone.**

Everything here was measured on one machine over several days of A/B runs, and every rejected
setting carries its counter-evidence. Roughly **80% of the settings I tried made things worse or did
nothing**. That ratio is the useful part.

> ⚠️ **If you are here to copy a config, read [`docs/07-corrections.md`](docs/07-corrections.md) first.**
> Two recommendations that were published here were wrong: `--batch 2` should be **deleted**, and
> `--max-context 131072` was **reverted**. Fixing the first is worth **13–16% of the expert cache**;
> the second means you would be trading context for slots you no longer need.

---

## TL;DR — the settings we tried, and where they landed

| Candidate | Verdict | One-line reason |
|---|---|---|
| **`--batch 2` → `parallel: 1`** | ✅ **adopted** | Production overlapped in 0.1–1.4% of requests. Deleting it won **+13–16% expert slots** at zero cost |
| **`STRATA_PREFILL_RING=384`** | ✅ **adopted** | A layer split silently shrinks the ring to 96. Restoring 384 = **+3.8% prefill**, **zero resident VRAM** |
| `--prefill auto:16384` | ✅ **kept** | Matched with ring 384. 8192 ties it; **20992 is −25.4%** (t = −6.11) |
| `--max-context 131072` | ⚠️ **reverted** | The same context now yields 13,767 slots vs 12,377 at 131072 — dropping `--batch` bought more than lowering the context |
| `--pipeline-windows 2` | ❌ rejected | −26.6% prefill, spread ×135. And `--batch` had been silently disabling it |
| `--conversation-cache-mib` | ❌ **off** (tried 10-20, reverted) | **−73%** on a 23K resume, but a 92K session parks 2.24 GiB at **22 MB/s = 72 s**, past the 60 s watchdog. Both deaths were in stage `parking` |
| `--lookup-chain 3` | ❌ rejected | Adds 3.5 draft tokens/request on prose; acceptance falls 82.1% → 79.6%; throughput +0.08 tok/s |
| `--suffix-draft 0` | ❌ rejected | −6.7% on echo, 1.7× the noise floor. The default (3) is doing real work |
| `--mtp-q4 all` | ❌ rejected | Draft layer **grows** 912 → 949 MiB. The Q4 copy is loaded *in addition*, not instead |
| `--prefill-head-alias` | 🚫 unavailable | Source refuses it here: layer split and `short_read` both disqualify |
| `--pool-workers` | 🚫 no headroom | 6 physical cores, 5 workers + host already use all of them |
| `--batch 3` | ❌ rejected | Peak concurrency is 2; 3 costs 0.69 GiB and 123 slots |
| `--kv-grow` | 🚫 unavailable | Requires `!multi_gpu` (`generate.cpp:4397`) — a layer split disqualifies it |
| `--kv-resident 40960` | ❌ rejected | **+3.9% slots for −6.9% decode**. It also proved the KV is only ~0.47 GiB, not the 3.87 GiB I had estimated |
| `--expert-cache-per-layer` | 🚫 closed | This box is already PROFILE-resident at 98–99% hit; the flag sizes `slots = q·48`, so it is not a clean A/B |
| `--calibrate` | 🚫 not applicable | It tunes `pcie_frac` / `spec_min_p` / `pool_workers` / `adapt` — all four are already settled, and it does not touch the prefill pipe |
| `STRATA_EMB_REUSE_ACCOUNT=1` | 🚫 no mechanism | Both of its outlets are pinned by this config (`--prefill auto:16384` and the env ring) |
| `rocBLAS` table filling | ❌ rejected | `default` rows are the calibrator's verdict, not blanks |

Full evidence for each: [`docs/04-what-not-to-tune.md`](docs/04-what-not-to-tune.md).
The three positive results have their own files:
[`docs/08`](docs/08-prefill-rings-and-chunks.md) (the ring),
[`docs/09`](docs/09-concurrency.md) (concurrency) and
[`docs/10`](docs/10-prefix-cache.md) (the conversation cache).

---

## The one thing to read first

If you only read one section of this repository, read
**[`docs/02-methodology.md`](docs/02-methodology.md)**.
If you only read one *other* section, read [`docs/07-corrections.md`](docs/07-corrections.md) —
it is where two of the recommendations below are taken back.

> **Decode throughput on this class of hardware has a ~5-request cold-start ramp
> after every restart *and after every workload change*.**
> Measuring from sample 1 gives you a number that is 30–40% too low, and worse,
> the bias differs per arm — so an A/B built on it produces confident nonsense.

My first A/B concluded "no difference" for the wrong reason: the within-arm spread
(32–44%) was larger than the effect I was chasing. The instrument was blunt, not the
setting neutral. Fixing that changed the verdicts.

---

## Hardware and baseline

| | |
|---|---|
| GPUs | 2× AMD Radeon Pro VII 16 GB (gfx906, **no `sramecc-`, xnack-**) |
| CPU | AMD Ryzen 5 2600 — **6 physical cores / 12 threads**, no AVX-512 (AVX2 only) |
| RAM | 48 GB (4 DIMMs, 8+16+8+16 @ 1866 MT/s) |
| Model | Qwen3.8-Flash-Next, **IQ3_XXS**, ~47 GB mmap'd |
| Engine | **0.1.45** today; the r17/r18 A/B below ran on **0.1.44.1** (`build-714`) |
| Split | `--layer-split auto` → layers 0–15 / 16–47, **`parallel: 1`** (no `--batch`) |

> **Version discipline.** Every absolute number here carries the engine version it came from.
> ✓/✗ verdicts are about mechanisms and travel between builds; tok/s does not.
> See [`docs/07 §C6`](docs/07-corrections.md#c6-version-labels-on-every-absolute).

Steady-state numbers from this box (measured, not quoted). **Do not compare across columns** — the
workloads and prompt lengths differ, and that is the point of listing them separately.

| Metric | 0.1.44.1, `--batch 2` | **0.1.45, `parallel: 1`** |
|---|---|---|
| Decode, 128–192 tok workloads | 49–52 (`count`), 56–60 (`echo`), 42.8–43.6 (`prose`) | 44.3–44.7 on 256-token prose (different workload) |
| Prefill, mixed prompts ≥4K | **485 tok/s** median (n=416) | not re-measured |
| Prefill, **32K fixed fixture** | — | **682.7 tok/s** median (n=7, ring 384) |
| Expert slots @ 163840 | 11,820 | **13,767** |
| Coverage | 13,900 / 24,576 (89.1%) | **13,952 / 24,576 (91.9%)** |
| Layer-split `K` | 20 | **16** (predicted 57.0 ms/window) |

> ⚠️ **Do not use "prefill tok/s" from reused requests as a capability number.**
> The engine reports `fresh_tokens / read_ms`. A request that reused 99% of its
> prompt reads 50 tokens in 1350 ms and reports 37 tok/s. That is a small workload,
> not a slow prefill. I have seen 21,434 tok/s quoted this way — it is noise.

---

## Repository layout

```
docs/
  01-hardware-and-baseline.md   what the machine is, and the numbers it should produce
  02-methodology.md             ★ the ramp, the A/B protocol, how to compute your own resolution
  03-readings.md                every measurement that a verdict rests on
  04-what-not-to-tune.md        ★ the rejections, with counter-evidence
  05-restart-runbook.md         ★ and the way `systemctl restart` can take your service down
  06-reproduce.md               how to re-run any of this on your own box
  07-corrections.md             ★ what I got wrong, and the evidence that overturns it
  08-prefill-rings-and-chunks.md  ★ the ring is 96 after a layer split; 384 is the free +3.8%
  09-concurrency.md             pipeline windows, `parallel: 1` vs `2`, and what 64 GB buys
  10-prefix-cache.md            reuse is 0.5 s or 55 s, never "sometimes slow"
  11-long-context-and-verify-timeout.md  ★ why a 100K session dies, and the log line that misleads
scripts/
  measure_steady.sh             decode: pre-condition + measure, with the hit-rate plateau check
  measure_prefill.py            prefill: nonce per request, `reused == 0` enforced, reads /metrics
  apply_config_safely.sh        edit → assert → stop → drain → start → prove, with rollback
results/
  README.md                     what the columns mean, and how to re-derive every table
  r17-lookup-chain-8arms.csv          312 rows · --lookup-chain 3 vs default · 8 arms
  r18-suffix-draft-mtp-q4-8arms.csv   312 rows · --suffix-draft 0 x --mtp-q4 all · 2x2 · 8 arms
  r19-prefill-chunk-4arms.csv         28 rows · chunk 16384 / 8192 / 20992, n=7 each
  r20-prefix-reuse.csv                9 rows · reuse is 0.48 s, eviction is 55 s
  r21-checkpoint-eviction.csv         9 rows · any other prompt discards the checkpoint
  r22-conversation-cache.csv          12 rows · budget 768 (fails) vs 1280 (works)
  r23-conversation-cache-multiplexed.csv  12 rows · 4 arms · the same flag on a multiplexed client
  r24-kv-resident.csv                 2 rows · --kv-resident 40960: +3.9% slots, −6.9% decode
  r25-long-context-restore.csv        3 rows · the 104K request that died, and one that did not
  r26-conversation-cache-rollback.csv 5 rows · why r23's flag came back off: 84 → 22 MB/s past ~600 MB
```

---

## What is specific to gfx906, and what generalises

**Specific to this card / this build** (do not assume it transfers):

- `--mtp-q4` behaviour (the Q4 copy being additive) is a property of this build's loader.
- `--prefill-head-alias` refusal is a combination of *this* config (layer split + `short_read`).
- Absolute tok/s numbers, and the `K` the placement search picks (it moved 20 → 16 between builds).
- The exact chunk where the ring saturates (20992 here) — it follows from `384 slots × layers`, so a
  different ring or a different expert count moves the cliff.

**Generalises to any Strata box, and to many live-service A/B studies:**

- The cold-start ramp and the need for pre-conditioning (docs/02).
- **Process age is a variance input, not a constant** — a 40 h process had 2.7× the spread of a fresh one
  at identical config, with the same median. Restart before *both* arms (`docs/07 §G1`).
- "Within-arm spread ≥ between-arm difference ⇒ noise" as a decision rule.
- Two same-config arms as a *measured* null, instead of an assumed one.
- **A layer split silently shrinks the prefill ring** to 96; one env var puts it back (`docs/08`).
- **The prefix cache is all-or-nothing** — a 1,986-token request discards a 38K checkpoint as
  completely as a 68K one (`docs/10`).
- **Your benchmark prompt is an evictor** — do not measure against a live service and then log the
  next production request as production latency.
- **`reading the prompt: N of M` counts reused tokens, not read ones.** 103,976 of 103,983 meant
  **7** tokens were read. The log is a progress display; `/metrics` is the measurement (`docs/11`).
- **The 5-second GPU wait behind `verify: timed out` is hard-coded, and disabling it is worse.** Fix
  why the GPU is slow, not the check (`docs/11`).
- **A verdict about a cache is a verdict about a workload, and workloads change.** "Serial client, so
  parking is wasted" was true on Monday and false on Wednesday, same binary, same config. Write the
  traffic shape next to the verdict (`docs/07 §C7`).
- The restart hazard: `ExecStop` may not kill the engine child (docs/05).
- GPU memory is reclaimed **asynchronously** after the process exits — poll for it.
- **A flag can be silently overridden** — `--pipeline-windows` was reset to 0 by `--batch` with no
  log line on the auto path. Check the banner, not the argument you passed.

---

## Credits and licence

Strata is [Niko1221/Strata](https://github.com/Niko1221/Strata), MIT.
The model is [Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next), compressed by ISTA-DASLab.
Nothing here is affiliated with or endorsed by the Strata maintainers; these are one user's measurements.

This repository: MIT (see [LICENSE](LICENSE)).
If a number here is wrong, the per-request CSVs in `results/` are the ground truth — please open an issue.
