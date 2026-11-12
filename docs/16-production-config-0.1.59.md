# The configuration as it actually runs (2026-11-12, engine 0.1.59)

> **Short version.** This page publishes the config the box runs *today*, in full, as
> [`../configs/production-config-0.1.59.json`](../configs/production-config-0.1.59.json).
> It is a redacted snapshot: **55 args and 45 env entries, with every numeric value preserved**.
> Only paths, the listening port and the public hostname are placeholders.
>
> Two statements earlier in this repository are now wrong and are corrected here (and as
> [`C17`](07-corrections.md)): **`--aux-cpus auto` has been removed**, and **`parallel` is back to
> `1`**, not `2`. Both were measured on engine 0.1.55, and both were reversed by later evidence on
> 0.1.59. If you copy a config from this repository, copy the JSON, not the prose from October.
>
> The other thing worth knowing: **the parameter layer is closed**. There is no untried flag left
> with a plausible gain above 1%. What limits decode now is structural — 36% of each window is GPU
> idle time spent on host-side work, and `wait` alone is 72.6% of the window. No flag reaches it.

Measurement basis: engine **0.1.59** (upstream v0.2.13 plus 11 local gfx906 patches), IQ3_S pack,
2× Radeon Pro VII 16 GB (gfx906), Ryzen 5 2600, 80 GB DDR4, `layer_split 26`, `parallel: 1`,
context 204800. Decode on real traffic: **56.2 tok/s hot**, measured ceiling **59.1**; prefill at
71K tokens: **845 tok/s**. Real traffic reuses **88.76%** of prompt prefixes, so prefill is at most
**5.71%** of wall time.

---

## 1. Why publish a snapshot now

This repository has always been a running record rather than an installation guide, and the
[`README`](../README.md) carries dated "what changed" sections that are deliberately left as
history. That convention has one failure mode: a reader who wants *the config* has to reconstruct it
from a dozen verdict tables, some of which describe an engine four releases ago.

The [11-02 scope note](../README.md) already warned that the box had moved to 0.1.55 / IQ3_S /
80 GB without a write-up. Since then it moved again (0.1.59) and two of the 11-02 conclusions were
overturned. Rather than rewrite history, this page adds the missing artifact: **one file that is the
config**, plus the reasoning needed to tell which values are portable and which are this machine's.

## 2. What was redacted, and how to use the file

| In the running config | In the published file | You substitute |
|---|---|---|
| Absolute install / model / pack paths | `<path>/...` | your own absolute paths |
| The model shard filenames | `<model>-0000N-of-00002.gguf` | your quant's shard names |
| Listening port (a fixed production port) | `"<port>"` | a **number**, e.g. `8080` |
| The public hostname in `allowed_hosts` | *(removed)* | your own hostname, if any |
| Engine / vision binary paths | `<path>/build/strata`, `<path>/vision/bin/...` | your build layout |
| Log and manifest paths | `<path>/strata-engine.log`, `<path>/manifest-slots24.json` | your paths |

Everything else is verbatim, including the values that look arbitrary (`822`, `256`, `a`, `16`, `8`).
The file is valid JSON and has the same top-level keys the server loader expects; `port` is the only
key whose **type** changes (string placeholder → integer) and must be edited before use.

Do not run [`scripts/apply_config_safely.sh`](../scripts/apply_config_safely.sh) against this file as
published — it is a template. Fill in the placeholders first.

## 3. The blocks, and why each value is what it is

| Block | Values | Evidence in this repository |
|---|---|---|
| **Two cards, serial** | `gpu: [0, 1]`, `layer_split: 26`, `parallel: 1` | A layer split is a hand-off, not parallelism: cards 0–25 → 26–47 + head + 2 drafters. Two cards add **capacity**, not compute. `parallel: 1` is what makes the server loader *not* inject `--batch`, which in turn lets pipeline windows actually enable. See [`docs/09`](09-concurrency.md) |
| **Expert cache** | `--expert-cache 11240`, `--mmap-experts`, `--vram-reserve-mib 1024`, `--vram-reserve-later-mib 822` | The chain is **VRAM → expert slots → hit rate → decode**. Slots scale with resident VRAM, so both reserve values are sized to the last MiB on these two 16 GB cards. `--mmap-experts` makes the OS page cache the effective tier behind them |
| **Conversation cache** | `40960` MiB / `24` slots / `min-tokens 4096` / `min-free-mib 12288` / `park-gain 8192` / `kv-resident 20480` | 24 slots give 24/24 revisits at **98.2%** reuse, 1.00 s vs 7.2 s cold. 40 GiB is capped against 80 GB RAM: a larger arena on a smaller machine pushes the page cache out and prefill collapses. See [`docs/10`](10-prefix-cache.md) and the rollback in [`docs/07`](07-corrections.md) |
| **Prefill** | `auto:16384`, `STRATA_PREFILL_RING=384`, `STRATA_HIP_PROMPT_F16=1`, `STRATA_ROCBLAS_TUNING` | 16384 is the rung the ring can cover; 20992 measured **−25.4%**. A layer split silently shrinks the ring to 96; 384 restores it. The rocBLAS solution table is **version-specific** and cannot be copied across ROCm releases |
| **Speculative decode** | `--spec 4`, `--spec-min-p 0.7`, `--pipeline-windows 2`, `--trim-stage-weights` | 4 / 0.7 is the sweet spot (6 was **−13%**). Pipeline windows only work once `--batch` is gone; the earlier rejection in this repository was measuring a flag that was silently disabled. See the correction in [`docs/07`](07-corrections.md) |
| **Host-side env switches** | 45 keys, all preserved | Most are 0/1 toggles for HIP-side kernel variants adopted one at a time with A/B evidence. `STRATA_IO_PREFETCH=0` is an explicit rejection (same decode, 33 fewer slots). `STRATA_PREFILL_CPU_SHARE=auto` is present but is documented upstream as having no effect on this backend — it is kept for provenance, not as a lever |
| **Diagnostics (temporary)** | `STRATA_DECODE_TIMING=1`, `STRATA_MANIFEST`, `STRATA_PARK_TRACE` | Instrumentation, not tuning. Scheduled for removal once 100K+ real windows have been collected. **Do not copy these into a production config** unless you are reproducing the measurement |

Two flags you will *not* find, deliberately:

- **`--aux-cpus auto`** — removed. See §5.
- **`--batch` / `--batch-mtp`** — absent. `parallel: 1` means the loader does not inject them;
  adding either one silently disables pipeline windows. A controlled two-stream test on 0.1.59
  measured a combined **75.13 tok/s** ceiling at a **−13.3%** single-stream cost, and was not
  adopted.

## 4. Values that are this machine's, not yours

These are the ones most likely to hurt if copied blindly:

- **`--expert-cache 11240` and both `--vram-reserve-*` values** — derived from 2 × 16 GB. On a
  different VRAM total the placement search picks a different `K`.
- **`--conversation-cache-mib 40960`** — sized against 80 GB RAM **and** a ~58 GiB page cache that
  `mmap-experts` needs. Raising it on a 61–64 GB machine was observed to drive the box into swap.
  Bigger is not better here.
- **`layer_split: 26`** — a layer boundary, not a percentage. 24 was measured at +0.8% (noise).
- **`STRATA_ROCBLAS_TUNING` pointing at a table directory** — the solutions in it are bound to one
  rocBLAS build. Copying a table from another version is not a valid optimisation.
- **`--mtp <path>/mtp/rt` and `data/expert-profile-iq3s-learned.bin`** — learned/profile artifacts from
  this traffic distribution. Re-learn them on yours.
- **`--adapt-every 4`** — the single most valuable env-class change on this box (decode 16.96 →
  33.00). It is still machine-specific; do not assume 4 is universal.
- **`vision` block** — a separate container-side binary. Optional, and currently a candidate for
  removal, not a recommendation.

## 5. Two corrections to the 11-02 notes

**C17 (high).** The 11-02 README section said `--aux-cpus auto` was **+1.26% and "now in
production"**, and the scope note said `parallel: 1 → 2`. On 0.1.59:

1. **`--aux-cpus auto` is gone.** It hard-pins prefill helper threads
   (`prefill.cpp` CPU affinity). A later, longer-context measurement found it costs **~61% of
   prefill throughput** on this host (519 → 838 tok/s after removal, time-to-first-token 114.4 →
   71.3 s). The original +1.26% was measured on a four-component decode window at 900 generated
   tokens, on a different engine version — it was real for that window and simply did not generalise
   to the prefill path. **[What changed]**: if you copied it for decode, remove it and re-measure
   prefill.
2. **`parallel` is `1`, not `2`.** Two-stream concurrency was re-tested with three controlled arms:
   `p1` 56.59, `p2 + --batch-mtp` 59.94 (rejected), `p2` without mtp 75.13 combined but only 37.56
   per stream and **−13.3%** single-stream. Real traffic is strictly serial. `parallel: 2` also
   reintroduces `--batch`, which disables pipeline windows on this engine.

Both are recorded in [`docs/07`](07-corrections.md) so the "read this before copying a config" page
stays authoritative. The 11-02 text is left in place as history with an inline pointer, by the same
convention as C1 and C12.

## 6. The parameter layer is closed; here is the ceiling

After the last four candidates were tested (mtp-window sizing, `STRATA_GDN_SPLIT=1`,
`STRATA_FUSE_WAIT=2`, and an empty-launch pruning idea), no adjustable flag remains with an expected
gain above ~1% — below the **5% threshold** this repository uses to call a result real. The remaining
time is structural:

| Component of one decode window (621 real windows) | ms | share |
|---|---:|---:|
| `wait` | 19.47 | 72.6% |
| host work | 3.12 | 11.6% |
| stage | 0.36 | 1.3% |
| residual | 3.85 | 14.4% |
| **total** | **26.80** | 1.45 tok/window |

The host-side slice is **36% GPU idle** (expert pool, adapt, commit, emit, stage-1). It is a
scheduling property of the split, not a knob. Getting past it means changing engine source or
hardware; both are outside the current return-on-effort threshold. See
[`docs/15`](15-why-decode-stops.md) for the four explanations that did not survive.

## 7. Verification checklist before you adopt any of this

1. Fill the placeholders, set `port` back to an integer, and start **one** engine.
2. Confirm `parallel: 1` and that the startup log shows pipeline windows **enabled** — the log line
   `is off: not with --batch slots` means the loader injected `--batch` and the flag is silently off.
3. Confirm two cards are visible and `layer_split` took effect; check resident VRAM and the expert
   slot count against your own card sizes.
4. Run a same-prefix multi-turn probe ([`scripts/multiturn_probe.py`](../scripts/multiturn_probe.py)),
   not a rotating-prompt harness. Report `reused` and hit rate next to decode.
5. Run the quality battery before and after any kernel-changing flag. Fused kernels change rounding;
   they are not bit-equivalent.
6. Only call a difference real at **≥5%**, measured in one process, adjacent windows, median of ≥6
   samples per arm, aligned by "Nth run after restart".

---

*Captured 2026-11-12 from a running `serve` process and its config file; verified that the engine's
actual command line matches the 55 args above. Redaction gate: `audit-redaction.ps1 -Strict`.*
