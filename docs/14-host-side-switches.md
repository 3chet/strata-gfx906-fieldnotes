# The last three host-side knobs, and the two instruments that were lying

> **Short version.** After every structural option had been closed, three parameter-level candidates
> were left. **Two are slower. One is 1.26% faster, and it is now in production.**
>
> The headline is not the 1.26%. It is that the two instruments this repository had been using for
> decode A/Bs **cannot resolve an effect that small** — one is confounded by the restart ramp, the
> other drifts with the hit rate. Both are standard practice, and both were wrong here. What replaced
> them is a sum of four components, reproducible to 0.19–0.57% within a batch.

Measurement basis: engine **0.1.55**, IQ3_S pack, `parallel: 2`, `--pool-workers 5`, Ryzen 5 2600
(6 cores / 12 threads), 80 GB RAM. Every arm below is 13 requests × 900 generated tokens.

> **⚠️ 2026-11-12 correction ([C17](07-corrections.md)).** The 1.26% winner below,
> `--aux-cpus auto`, is **no longer in production**. Every measurement on this page stands for
> 0.1.55 and for a 900-token decode window; on 0.1.59 the flag hard-pins prefill helper threads and
> costs ~61% of prefill, so it was removed. `parallel` is `1` again. For the config the box runs
> today, use [`configs/production-config-0.1.59.json`](../configs/production-config-0.1.59.json)
> and [`docs/16`](16-production-config-0.1.59.md).

---

## 1. Instrument one: end-to-end decode across a restart

The natural A/B is "same config, measure decode, change one flag, restart, measure again". That is what
`docs/02-methodology.md` recommends, with a five-request preconditioning discard. It still does not
work for effects in the 1–3% range, and the table below is why.

| arm | when | median | mean | verdict |
|---|---|---:|---:|---|
| default | process up 7 h 42 min | **47.80** | 47.49 | baseline |
| `--pool-tasks 64` | fresh restart | 46.20 | 46.06 | looks like −3.3% |
| `--pool-tasks 64`, re-run | same process, steady | 45.60 | — | consistent with above |
| **default, fresh restart (control)** | fresh restart | **44.10** | 44.99 | ← the control is *slower* than the arm it was meant to beat |

The control arm, on the configuration the first row measures at 47.80, came back at **44.10**. The gap
between "long-running" and "just restarted" is **3.7 tok/s — larger than every effect being tested.**

The ramp is not the five requests `docs/02` budgeted for. Traces here show the first measured sample
of a fresh process as low as **19.6 tok/s**, and a return to the plateau only after ~10 minutes:
the expert profile is still learning and the page cache is still warming. Five requests take ~20 s.

**Consequence:** any decode A/B that spans a restart is measuring the ramp, not the flag. This is why
`--pool-tasks 64` first read as a 3.3% loss and the control then read as a 3.7% loss on the *baseline*
— two numbers that cannot both be the flag's fault.

> Same-process A/B avoids this entirely. It is available for anything that does not need a restart:
> environment variables read per request, runtime knobs, and the DPM experiments in
> [`15-why-decode-stops.md`](15-why-decode-stops.md).

## 2. Instrument two: one component of the split, taken alone

When a restart *is* required, the obvious substitute is the engine's own per-window accounting:
`wait`, `pool + plan`, `staging`, `commit`. Read the component you intended to move and compare.

That also fails, for a reason that took two contradictory readings to see:

| arm | `pool + plan`, stage 0 + 1 | reading |
|---|---:|---|
| default | 4.519 ms | baseline |
| `--aux-cpus auto`, first run | **4.290 ms** | "−5.1%, free win" |
| `--aux-cpus auto`, repeat | **4.656 ms** | "worse than baseline" |
| default, repeat | 4.519 ms | unchanged |

Same binary, same config, same flag — **−5.1% then +3.0%**. The difference between the runs was the
expert-cache hit rate (0.974 in the good run, 0.962 in the bad one). A miss costs the CPU pool real
work, so `pool + plan` tracks the hit rate; and `wait` moves the opposite way to compensate, because a
cheaper pool lets the GPU start earlier and therefore *waits longer* for it.

**The four components are one measurement, not four.** Judge on their sum:

```
window = wait + pool + plan + staging + commit
```

Re-read the same data that way and the picture becomes stable:

| arm | stage 0 | stage 1 | **total** | vs baseline |
|---|---:|---:|---:|---:|
| default (run 1) | 18.930 | 15.197 | **34.127** | — |
| default (run 2) | 18.912 | 15.023 | **33.935** | within-batch spread **0.57%** |
| `--aux-cpus auto` (run 1) | 18.717 | 14.918 | **33.635** | **−1.16%** |
| `--aux-cpus auto` (run 2) | 18.712 | 14.858 | **33.570** | **−1.35%**, spread **0.19%** |
| `--aux-cpus auto` + `STRATA_POOL_SPIN_US=50000` | 18.805 | 15.005 | 33.810 | +0.62% vs aux (rejected) |

Between-arm difference 1.26% > within-arm spread 0.57% ⇒ the effect is real. It is just very small.

## 3. The three switches

### 3.1 `--aux-cpus auto` — adopted, +1.26%

The flag moves threads that belong to neither the host nor the pool (driver, HIP callbacks, the serve
side) onto a sibling of the host core, and **never onto a core a worker owns**.

The placement evidence is unambiguous. Bound threads per logical CPU, before and after:

| CPU | before | after |
|---|---:|---:|
| 0 (host core) | **9** | **1** |
| 1–5 (pool workers) | 1 each | 1 each |
| 6 (host's SMT sibling) | 0 | **27** |
| 7–11 (workers' siblings) | 0 | 0 — correctly excluded |

So the mechanism is not "more parallelism". It is that the host thread — which is itself one of the
six pool shards, and which publishes the doorbell flags the GPU waits on — stops sharing a core with
eight other threads. The gain lands exactly where that predicts:

| component | default | `--aux-cpus auto` |
|---|---:|---:|
| `wait` (stage 0 / 1) | 15.347 / 13.464 | 15.00 / 13.22 |
| `commit` (stage 0 / 1) | 0.674 / 0.256 | 0.470 / 0.181 |
| **`pool + plan`** | 4.519 | no change within noise |

**`pool + plan` did not move.** If the pitch for the flag had been "the pool gets faster", the
measurement refutes it. It is the signalling path that got faster.

Cost: none. The source comment for the mechanism says it *"moves threads only, never a result"*, and
the acceptance test confirms it: `slots`, `vram_free` and the hit rate are byte-identical afterwards.

### 3.2 `--pool-tasks 64` — rejected, +8.2% on the thing it targets

Reasoning for trying it: the pool splits each layer's rows into tasks and the workers claim them with
a `fetch_add` race, so a coarser task count should leave a ragged tail. The default resolves to
`3 × (workers + 1) = 18`.

The premise about task size was wrong in a way worth recording. **A task is a row, not an expert.**
`mrows_ = n × FF` with `FF = 640`, so a layer offers ~26,880 rows against 18 claims — the tail is one
task wide, at most 1/18 of the phase, not the 30–40% the "one task per expert" mental model suggests.

Measured on the target component (this arm predates the four-component rule, but it moves the component
it was designed to move, by 3.5× the effect):

| task count | `pool + plan` stage 0 | stage 1 | total | windows |
|---|---:|---:|---:|---:|
| 18 (default) | 3.047 | 1.472 | **4.519 ms** | 6,386 |
| 64 | 3.213 | 1.678 | **4.891 ms (+8.2%)** | 6,629 |

Coarser is not the fix, finer is the cost. The claim is already a dynamic race — 18 tasks over 6
threads is enough for the tail to be one task — so raising it to 64 only multiplies atomic contention
by 3.5×. Stage 1 (small tasks) loses the most, +14%.

**Verdict: rejected.** Not tested at 128; the direction is established and monotone.

### 3.3 `STRATA_POOL_SPIN_US=50000` — rejected, +0.62%

The workers spin before sleeping, and the default threshold is **20 ms**. Inspecting the boundary is
tempting: the single-stream window is ~23 ms and the dual-stream window is ~18.2 ms, so at 20 ms a
single-stream worker just barely sleeps between layers while a dual-stream worker does not.
Raising the threshold to 50 ms should therefore remove a sleep/wake per layer on single stream.

It does not pay. Stacked on top of `--aux-cpus auto`, which is the strictest test available:

| | total |
|---|---:|
| `--aux-cpus auto` alone | **33.570 ms** |
| \+ `SPIN_US=50000` | 33.810 ms (+0.62%) |

A worker that keeps spinning holds its core. When the wake-up latency saved is smaller than the
contention added — and at 5 workers on 6 cores, with the host sharing — it is a net loss.

**Verdict: rejected. The 20 ms default is correct; do not touch it.**

## 4. The part worth reusing: two timers that need no patching

Both instruments in §1–2 come from the engine's own instrumentation. Neither requires a rebuild, and
both are the reason this round took minutes per arm instead of an afternoon.

### 4.1 `STRATA_SPLIT_TIMING=1` — per-window, accumulated per stage

```
strata serve: stage 0: 6386 windows; per window: wait for the GPU 15.347 ms,
  pool + plan 3.047 ms, staging 0.133 ms, commit 0.650 ms
strata serve: stage 1: 6386 windows; per window: wait for the GPU 13.464 ms,
  pool + plan 1.472 ms, staging 0.001 ms, commit 0.256 ms
```

Read it as **the host's wall clock between two GPU hand-offs**, split four ways:

| field | meaning | why it matters |
|---|---|---|
| `wait` | the host blocking until the GPU reaches a given layer | 71% of the window; the structural floor |
| `pool + plan` | publishing the plan, activating rows, then running the CPU's share of the experts | this is the part a flag can move |
| `staging` | copying the CPU result into the GPU's buffer | ~0.1 ms, never worth tuning |
| `commit` | publishing the doorbell for the next layer | landed the `--aux-cpus` gain |

**Read the sum, per §2.** And note the field named `wait` is not all the waiting: it covers the
hand-off, not the GPU's own execution, which is why `verify` (33.65 ms) exceeds
`wait + pool + staging` (17.44 ms) on the same windows.

Log location matters: these lines go to the **engine's** log, not the server's. The server log carries
a `[strata]`-prefixed digest and the engine rewrites its own file on every start.

### 4.2 `STRATA_DECODE_TIMING=1` — per request, four more numbers

```
strata decode timing: verify 33.65 ms over 4021 windows | plan 0.12 | actq 0.07 | jobs 0.01 | run 3.45
```

`plan` / `actq` / `jobs` / `run` are per-window means inside the dispatch: publish the plan, quantise
the activations, hand out the tasks, run them. This is how the "+18~27% from overlapping the pool" claim
was killed — see [`15-why-decode-stops.md §2`](15-why-decode-stops.md).

## 5. What this closes

Parameter-level tuning on this configuration is done, and the honest total is **+1.26%**:

| candidate | result | status |
|---|---|---|
| `--aux-cpus auto` | −1.26% window total, reproducible | ✅ **in production** |
| `--pool-tasks 64` | +8.2% on `pool + plan` | ❌ rejected |
| `STRATA_POOL_SPIN_US=50000` | +0.62% on top of aux | ❌ rejected |
| `--pool-workers 6` | not tested — CPU 6 is now taken by aux; upper bound 3.8% | ⛔ skipped |
| re-learn the expert profile | 1–2% expected, hit rate already 0.97–0.99 | open, low value |

`--pool-workers 6` is worth a sentence, because it is the one candidate skipped rather than refuted.
Above 5 workers the engine hands out `core = -1` for the surplus and **silently does not pin it**
(`pool.cpp`, the ternary falls through to `pin_this_thread(-1)`, which returns false). The thread then
floats under the scheduler — it may land on an idle SMT sibling, or on one already owned by a worker,
where it shares the core's load/store bandwidth. Uncontrolled is not an experiment, and it is
mutually exclusive with `--aux-cpus auto` anyway: aux claims the sibling slots first.

Raw aggregates, with the caveat that they are reconstructed from the log lines above rather than kept
per-request samples: [`results/r34-host-side-switches.csv`](../results/r34-host-side-switches.csv),
[`results/r35-pool-tasks-and-plan.csv`](../results/r35-pool-tasks-and-plan.csv).
