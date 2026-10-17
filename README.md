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

---

## TL;DR — the settings we tried, and where they landed

| Candidate | Verdict | One-line reason |
|---|---|---|
| `--lookup-chain 3` | ❌ rejected | Adds 3.5 draft tokens/request on prose; acceptance falls 82.1% → 79.6%; throughput +0.08 tok/s |
| `--suffix-draft 0` | ❌ rejected | −6.7% on echo, 1.7× the noise floor. The default (3) is doing real work |
| `--mtp-q4 all` | ❌ rejected | Draft layer **grows** 912 → 949 MiB. The Q4 copy is loaded *in addition*, not instead |
| `--prefill-head-alias` | 🚫 unavailable | Source refuses it here: layer split, `--batch`, and `short_read` all disqualify |
| `--pool-workers` | 🚫 no headroom | 6 physical cores, 5 workers + host already use all of them |
| `--prefill` chunk > 16384 | ❌ rejected | Needs double prompt buffers; the measured gain was a composition artefact |
| `--max-context 163840 → 131072` | ✅ **adopted** | +557 expert slots (+4.7%), +192 covered pairs, decode unchanged |
| `--batch 3` | ❌ rejected | Production peak concurrency is 2; 3 costs 0.69 GiB and 123 slots |
| `rocBLAS` table filling | ❌ rejected | `default` rows are the calibrator's verdict, not blanks |

Full evidence for each: [`docs/04-what-not-to-tune.md`](docs/04-what-not-to-tune.md).

---

## The one thing to read first

If you only read one section of this repository, read
**[`docs/02-methodology.md`](docs/02-methodology.md)**.

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
| RAM | 48 GB |
| Model | Qwen3.8-Flash-Next, **IQ3_XXS**, ~47 GB mmap'd |
| Engine | Strata 0.1.44.1, `build-714`, inside Docker |
| Split | `--layer-split auto` → 2 GPUs, `--batch 2` |

Steady-state numbers from this box (measured, not quoted):

| Metric | Value |
|---|---|
| Decode, short answers | 49–52 tok/s (`count`), 56–60 (`echo`), 42.8–43.6 (`prose`) |
| **Prefill, fresh work** | **485 tok/s median** (zero-reuse prompts ≥4K, n=416); 548–620 for long prompts |
| Expert slots | 11,820 at 163840 → **12,377** at 131072 |
| Coverage | 13,900 / 24,576 profiled pairs (**91.3%** of routed mass) |

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
scripts/
  measure_steady.sh             pre-condition + measure, with the hit-rate as a plateau check
  apply_config_safely.sh        edit → assert → stop → drain → start → prove, with rollback
results/
  README.md                     what the columns mean, and how to re-derive every table
  r17-lookup-chain-8arms.csv          312 rows · --lookup-chain 3 vs default · 8 arms
  r18-suffix-draft-mtp-q4-8arms.csv   312 rows · --suffix-draft 0 x --mtp-q4 all · 2x2 · 8 arms
```

---

## What is specific to gfx906, and what generalises

**Specific to this card / this build** (do not assume it transfers):

- `--mtp-q4` behaviour (the Q4 copy being additive) is a property of this build's loader.
- `--prefill-head-alias` refusal is a combination of *this* config (split + batch + short-read).
- Absolute tok/s numbers.

**Generalises to any Strata box, and to many live-service A/B studies:**

- The cold-start ramp and the need for pre-conditioning (docs/02).
- "Within-arm spread ≥ between-arm difference ⇒ noise" as a decision rule.
- Two same-config arms as a *measured* null, instead of an assumed one.
- The restart hazard: `ExecStop` may not kill the engine child (docs/05).
- GPU memory is reclaimed **asynchronously** after the process exits — poll for it.

---

## Credits and licence

Strata is [Niko1221/Strata](https://github.com/Niko1221/Strata), MIT.
The model is [Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next), compressed by ISTA-DASLab.
Nothing here is affiliated with or endorsed by the Strata maintainers; these are one user's measurements.

This repository: MIT (see [LICENSE](LICENSE)).
If a number here is wrong, the per-request CSVs in `results/` are the ground truth — please open an issue.
