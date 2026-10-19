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

Expect roughly (on gfx906 dual-GPU, **0.1.44.1 with `--batch 2`**): `count` 49–52, `echo` 56–60,
`prose` 42.8–43.6 tok/s. On **0.1.45 with `parallel: 1`** the same box gives 44.3–44.7 on 256-token prose
— a different workload, so do not read it as a regression.
**Your absolute numbers will differ** — what transfers is the *shape*: sample 1 well below the plateau,
a per-workload ramp, MAD around 0.2–1.9 tok/s at steady state.

---

## 1b. Measure prefill (different rules — read them first)

```bash
# needs STRATA_LOG unset; reads /metrics instead
python3 scripts/measure_prefill.py --chars 53000 --samples 7 --tag baseline --out arm.csv
```

`53000` Chinese characters ≈ **32K tokens** (0.6 tok/char). Pass `--corpus your_text.txt` to use real
prose instead of the built-in synthetic fixture.

Three things this script does that a naive one does not:

- **A unique nonce at the front of every request.** Without it, request 2..N reuse 99.9% of the prompt
  and you are measuring a 72 ms cache hit, not prefill.
- **Reads `prompt_read / prompt_ms` from `/metrics`.** The engine's DONE line reports the same ratio, but
  for a reused request both halves collapse to noise.
- **Discards the first sample and refuses samples where `reused != 0`.**

Judge at 32K (1–2% variance). At 68K the per-sample variance is ±15%, so n=7 cannot resolve a 4% effect —
use it for direction only.

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

Measured cost on this box, for reference — so you know what you are trading when you decide:

| | `parallel: 1` | `parallel: 2` |
|---|---:|---:|
| single request | **44.3–44.7** | 40.9 (−8.3%) |
| two requests at once (aggregate) | 43.0 (queued) | **48.4 (+12.6%)** |
| expert slots | 13,529–13,767 | 11,901 (−12%) |

So: **overlap regularly → 2. One session at a time → 1.** Note that prefill does not benefit at all —
two long prompts are processed strictly serially regardless ([09 §2](09-concurrency.md#2-parallel-2--a-real-126-if-you-actually-overlap)).

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

**Set `"fit_max_tokens": true` in the model JSON while you are in there.** With it, the server shortens
`max_tokens` to the room left instead of returning 400 — the context limit becomes a degradation rather
than an outage. Without it, every request that lands near the ceiling is a hard failure.

**And do not lower the context to buy expert slots without checking `expert_slots` first.** On a box
that has already dropped `--batch`, the number is already ≥13.5K and the old +557-slot argument is noise
against it ([07 §C2](07-corrections.md#c2-revert-max-context-to-163840)).

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
- **Anything measured on a long-running process, at the same config.** A 40 h process here had 2.7× the
  prefill spread of a fresh one with the same median. If you compare against a number taken on a process
  that has been up for days, you are comparing age as well as config.
- **Where the prefill chunk saturates.** 20992 is 384 slots × 48 layers on this box. A different ring, a
  different layer count or a different expert distribution moves the cliff; the *existence* of a cliff is
  what generalises.
- **`--mtp-q4` behaviour.** The "Q4 copy is additive" result is a property of this build's loader; verify
  from your own startup lines (`draft layer loaded, N MiB of VRAM`) rather than trusting this repo.
- **`--prefill-head-alias` availability.** It depends on your split/short-read combination, not on the
  GPU alone. Check the refusal message.
- **Text output.** Greedy answers are not reproducible across restarts even with an identical config, so
  you cannot use text as a cross-run correctness criterion. See
  [`docs/02-methodology.md` §4.3](02-methodology.md#43-greedy-output-is-not-reproducible-across-restarts).

---

## 7. If you find a number here that is wrong

Please open an issue with your `results/`-style CSV and the engine's startup block. The raw per-request
samples in `results/` are the ground truth for everything in this repository; a disagreement there is
the most useful kind of report.
