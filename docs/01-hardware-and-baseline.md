# Hardware and baseline

## The machine

| | |
|---|---|
| GPUs | 2× AMD Radeon Pro VII 16 GB, **gfx906**, wave64 |
| GPU arch flags | `sramecc-`, `xnack-` (no ECC control, no XNACK) |
| CPU | AMD Ryzen 5 2600 — **6 physical / 12 logical**, AVX2 only (**no AVX-512**) |
| RAM | 48 GB |
| Storage | SSD; experts are `--mmap-experts`, read through the OS file cache |
| OS | Ubuntu, kernel as shipped; ROCm from the community gfx906 build |
| Runtime | Strata 0.1.44.1 inside Docker |

The engine's own startup line on the CPU is worth quoting because it constrains everything downstream:

```
strata generate: this CPU has no AVX-512: the expert kernels run on AVX-2
                 (multi-token for the i-quant gate/up rows)
```

On a 6-core Zen+ part, CPU-side expert work is the scarce resource. That is why `--pool-workers` has no
headroom (see [04](04-what-not-to-tune.md#5---pool-workers--physically-no-headroom)).

## Model and split

| | |
|---|---|
| Model | Qwen3.8-Flash-Next, **IQ3_XXS** (~47 GB across two GGUF shards) |
| Experts | 24,576 profiled pairs |
| MTP | yes, `--spec 4 --spec-min-p 0.7` |
| Split | `--layer-split auto` → CUDA0 layers 0–16, CUDA1 layers 17–47 |
| Batch | `--batch 2` (2 slot sessions, one per card) |

`--layer-split auto` runs a placement search over 46 candidates and prints its choice and predicted cost:

```
strata generate: layer split auto: K=17 - predicted 58.5 ms per decode window;
                 the caches hold 14092 of 24576 profiled pairs (~91.3% of the routed mass),
                 best of 46 placements
```

**That `K` is not stable across configurations.** It is a function of the expert profile's ranking and
the free VRAM. See the warning in [02 §4.4](02-methodology.md#44-learned-state-is-an-input-on-the-next-boot).

## Baseline numbers to expect

Steady state, `temperature: 0`, after pre-conditioning (see [02](02-methodology.md)):

### Decode

| workload | output cap | median tok/s | spread (MAD) |
|---|---:|---:|---:|
| `count` (count 1..60) | 128 | 49–52 | 0.7–1.9 |
| `echo` (repeat a passage) | 192 | 56–60 | 0.2–1.5 |
| `prose` (original writing) | 192 | 42.8–43.6 | 0.3–0.9 |

The bands are ranges across repeated arm runs, not one run. **The between-run spread is your null** — if
your change is smaller than this, you cannot see it.

### Prefill

Only **zero-reuse** requests measure prefill capacity. n=416 such requests (prompt ≥4096 tokens):

| | p25 | **median** | p75 | p90 | max |
|---|---:|---:|---:|---:|---:|
| tok/s | 458 | **485** | 535 | 577 | 689 |

By prompt length (zero-reuse only):

| prompt tokens | n | median tok/s | median wall |
|---|---:|---:|---:|
| 4K–16K | 320 | 475 | 22.5 s |
| 16K–32K | 32 | 548 | 41.5 s |
| 32K–48K | 14 | 548 | 72.1 s |
| 48K–64K | 40 | 620 | 90.2 s |
| 64K–128K | 7 | 580 | 132.0 s |

Short prompts score *lower* — fixed per-request overhead amortised over less work. Long prompts are the
honest prefill number.

> **Anti-pattern to avoid:** the engine prints `(N tok/s)` on its DONE line as
> `fresh_tokens / read_ms`. A request that reused 99% of its prompt reads ~50 tokens and reports
> ~37 tok/s. Averaging those in produces nonsense (42–49 tok/s across all production requests). I have
> seen the opposite error too — quoting 21,434 tok/s from heavily reused requests as "prefill speed".
> Neither is a capacity measurement.

### Where the time actually goes

| production epoch | prompt time | decode time | prefill share |
|---|---:|---:|---:|
| A | 0.41 h | 0.29 h | **58.8%** |
| B | 1.19 h | 1.86 h | **39.1%** |

Prefill is 39–59% of engine time. That is the ceiling on any prefill-side optimisation — a 10% prefill
win is 4–6% of total.

## VRAM ledger (this is deterministic, not sampled)

The engine prints its allocation at every start. Changing `--max-context` moves it exactly as predicted:

| | 163840 | 131072 |
|---|---:|---:|
| CUDA0 slot session | 0.63 GiB | **0.42 GiB** |
| CUDA1 slot session | 0.87 GiB | **0.80 GiB** |
| CUDA0 expert slots | 6,801 | **7,297** |
| CUDA1 expert slots | 5,019 | **5,080** |
| **total slots** | 11,820 | **12,377** |
| covered pairs / 24,576 | 13,900 (89.1%) | **14,092 (91.3%)** |

Two runs at 131072 gave **identical** figures (12,347 in an earlier, differently-profiled run; the
number is reproducible per configuration). Allocation is deterministic — if it moves between two runs of
the same config, something else changed.

## What `--max-context` actually costs you

Requests whose prompt + `max_tokens` exceed the context are **rejected with HTTP 400, never truncated**.
Both sides say so:

```
server.py:  "Requests whose prompt plus max tokens exceed the engine's context are
             REJECTED with 400, never truncated."

generate.cpp: if (n + max_new + 8 > o.max_context) {
                  printf("ERR prompt (%lld tokens) + max_new (%lld) exceeds the context (%lld)\n", ...);
                  continue;
              }
```

Observed response for a deliberately oversized prompt:

```json
{"error": {"type": "invalid_request_error",
  "message": "request exceeds the context window: prompt (951666 tokens) + max tokens (8)
   exceeds the context (131072); requests are never truncated.
   Send a smaller max_tokens (at most 0 here), or add \"fit_max_tokens\": true ..."}}
```

So the risk of lowering `--max-context` is **availability for very long prompts**, not silent data loss.
On this box the longest real prompt observed was **103,639 tokens** (production epochs only), leaving 21%
headroom at 131072. Prompts above 131072 existed only in a benchmark epoch.

**Check your own distribution before copying this number:**

```bash
grep -oE 'prompt [0-9]+ tokens = ' engine.log | grep -oE '[0-9]+' | sort -n | tail -20
```
