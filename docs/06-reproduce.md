# Reproduce any of this on your own box

You need: a running Strata server, `bash`, `curl`, `python3` (stdlib only — no numpy, no pandas).
The scripts in `scripts/` send HTTP requests and (optionally) read the engine log. They do not modify
your service.

---

## 0. Point the scripts at your server

Nothing is hard-coded. Every host detail is an environment variable:

```bash
export STRATA_HOST=127.0.0.1
export STRATA_PORT=8080
export STRATA_MODEL=strata                  # any name your server accepts
export STRATA_LOG=/path/to/strata-engine.log # optional; enables hit-rate capture
# export STRATA_API_KEY=...                 # only if your server needs one
```

With `STRATA_LOG` set, the scripts also record the **expert-cache hit rate**, which is how you verify
you are on the plateau rather than still climbing.

---

## 1. Measure steady state (one arm)

```bash
bash scripts/measure_steady.sh
```

Defaults: 5 discarded preconditioning requests per workload, then 8 measured, across three workloads
(`count`, `echo`, `prose`). Writes a CSV.

Expect roughly (on gfx906 dual-GPU with `--batch 2`): `count` 49–52, `echo` 56–60, `prose` 42.8–43.6 tok/s.
**Your absolute numbers will differ** — what transfers is the *shape*: sample 1 well below the plateau,
a per-workload ramp, MAD around 0.2–1.9 tok/s at steady state.

---

## 2. Run an A/B properly

One arm is not a measurement of a change. You need:

- **two arms per configuration**, identical config, on **separate restarts** — their difference is your null;
- **palindromic order** (`A B B A`) so drift cancels;
- the same `measure_steady.sh` per arm.

Then fit, per workload:

```
y = a + b·t + c·group
```

`t` = arm start time in minutes (centred), `group` = 0/1. `b` is drift, `c` is your effect, and the
resolution is `2·SE(c)`. A minimal implementation is in
[`docs/02-methodology.md` §3](02-methodology.md#33-judging).

**Validate the fit on synthetic data first.** Generate arms with a known effect planted under a known
drift, and confirm you recover both. If you cannot, your verdicts are worthless.

### Reporting it

- median, not mean; give MAD alongside
- state your resolution, in tok/s and in %
- a verdict of "no difference" **requires** the resolution number, or it is not a finding
- if one workload has a poor null (say 5%), say so and exclude it from the decision rather than
  averaging it in

---

## 3. Check whether concurrency exists before tuning for it

`--batch N` costs VRAM whether or not requests overlap. Count the overlap in your own log:

```bash
# a slot is held from "takes" until "gave back"; two held at once is real overlap
grep -o 'strata batch: slot [0-9]* \(takes\|gave back\)' engine.log | head -50
```

If you never see two slots held, `--batch` above 1 is pure VRAM cost for your workload.

Also useful — duty cycle, i.e. how much of wall time is spent doing anything:

```bash
# sum of (read ms + generate ms) across requests, divided by the wall span of the lifetime
grep -oE 'read in [0-9]+ ms|generated in [0-9]+ ms' engine.log | grep -oE '[0-9]+'
```

---

## 4. Check your prompt-length distribution before lowering `--max-context`

Requests over the limit get HTTP **400**, never truncated — so the risk is availability, not data loss.

```bash
# longest prompts you have actually served
grep -oE 'prompt [0-9]+ tokens = ' engine.log | grep -oE '[0-9]+' | sort -n | tail -20
```

Compare the max against the context you plan to set, and leave headroom for growth. On my box the
longest real prompt was 103,639 tokens against a new limit of 131,072 — 21% headroom. The prompts that
exceeded it existed only in a benchmark run, not in traffic.

---

## 5. Apply a config change without taking the service down

```bash
export STRATA_CFG=/path/to/strata-<model>.json
export STRATA_FLAG=--max-context
export STRATA_VALUE=131072
export STRATA_UNIT=strata-<model>.service
export STRATA_CONTAINER=<container>              # if the engine runs in Docker
export STRATA_GPU_MIB_CMD='rocm-smi --showmeminfo vram | grep "Used Memory (B)" | grep -oE "[0-9]{6,}" | head -2 | awk "{printf \"%d %d\n\", \$1/1048576, \$2/1048576}"'
export STRATA_HEALTH_URL=http://127.0.0.1:<port>/health
export STRATA_STATUS_URL=http://127.0.0.1:<port>/v1/status
export STRATA_CHAT_URL=http://127.0.0.1:<port>/v1/chat/completions

bash scripts/apply_config_safely.sh
```

Run it once with `STRATA_DRY_RUN=1` first: it snapshots, edits, verifies the write, then restores —
without touching the service.

The script implements all three gates and the drain wait described in
[`docs/05-restart-runbook.md`](05-restart-runbook.md). **The drain wait matters:** GPU memory is
reclaimed asynchronously, so a process being gone does not mean the VRAM is free.

---

## 6. What will *not* reproduce

- **Absolute tok/s.** Different card count, ROCm build, CPU and RAM all move it by tens of percent.
- **`--mtp-q4` behaviour.** The "Q4 copy is additive" result is a property of this build's loader; verify
  from your own startup lines (`draft layer loaded, N MiB of VRAM`) rather than trusting this repo.
- **`--prefill-head-alias` availability.** It depends on your split/batch/short-read combination, not on
  the GPU alone. Check the refusal message.
- **Text output.** Greedy answers are not reproducible across restarts even with an identical config, so
  you cannot use text as a cross-run correctness criterion. See
  [`docs/02-methodology.md` §4.3](02-methodology.md#43-greedy-output-is-not-reproducible-across-restarts).

---

## 7. If you find a number here that is wrong

Please open an issue with your `results/`-style CSV and the engine's startup block. The raw per-request
samples in `results/` are the ground truth for everything in this repository; a disagreement there is
the most useful kind of report.
