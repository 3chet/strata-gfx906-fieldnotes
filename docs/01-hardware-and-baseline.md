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
| Runtime | Strata inside Docker — **0.1.45 today**; the r17/r18 A/B below ran on **0.1.44.1** |

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
| MTP | yes, `--spec 4 --spec-min-p 0.7` (the effective verify width is 6 — see [07 §G3](07-corrections.md#g3-metrics-spec-is-not-argv-spec)) |
| Split | `--layer-split auto` → CUDA0 layers 0–15, CUDA1 layers 16–47 |
| Batch | **none** — `"parallel": 1`. `--batch 2` was measured to cost 13–16% of the expert cache ([07 §C1](07-corrections.md#c1-delete-batch-2-do-not-keep-it)) |

`--layer-split auto` runs a placement search over 46 candidates and prints its choice and predicted cost:

```
strata generate: layer split auto: K=16 - predicted 57.0 ms per decode window;
                 the caches hold 13952 of 24576 profiled pairs (~91.9% of the routed mass),
                 best of 46 placements
```

(That block is the 0.1.45 line as it reads today. The 0.1.44.1 run quoted elsewhere in this repository
said `K=17 / 58.5 ms / 14,092 / 91.3%`; the two are not comparable, which is why the version is on
every table. Note the capital `K` here is the layer split point, not `--lookup-chain K`.)

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

### Prefill on 0.1.45, fixed fixture (do not compare with the table above)

The table above is 0.1.44.1 with a production prompt mix. These are 0.1.45 with one fixed 32,209-token
fixture and a fresh nonce per request:

| configuration | median tok/s | n |
|---|---:|---:|
| `auto:16384`, ring 384 (**current**) | **682.7** | 7 |
| `auto:16384`, ring 96 (layer-split default) | 657.7 | 7 |
| `auto:12288` → chunk 8192, ring 384 | 690.2 | 7 |
| `auto:32768` → chunk 20992, ring 384 | 521.4 | 7 |

A fixed fixture with a fixed prompt length is the only way to compare two prefill settings; the
production table cannot do it, because its bucket composition moves with every change. See
[08](08-prefill-rings-and-chunks.md) for the ring and the chunk-ladder measurements.

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

| | 163840 / 0.1.44.1 | 131072 / 0.1.44.1 | **163840 / 0.1.45, no batch** |
|---|---:|---:|---:|
| CUDA0 slot session | 0.63 GiB | **0.42 GiB** | — |
| CUDA1 slot session | 0.87 GiB | **0.80 GiB** | — |
| CUDA0 expert slots | 6,801 | **7,297** | **7,836** |
| CUDA1 expert slots | 5,019 | **5,080** | **5,931** |
| **total slots** | 11,820 | **12,377** | **13,767** |
| covered pairs / 24,576 | 13,900 (89.1%) | **14,092 (91.3%)** | **13,952 (91.9%)** |
| K / predicted window | 20 / 68.4 ms | 17 / 58.5 ms | **16 / 57.0 ms** |

Two runs at 131072 gave **identical** figures (12,347 in an earlier, differently-profiled run; the
number is reproducible per configuration). Allocation is deterministic — if it moves between two runs of
the same config, something else changed.

> ⚠️ **The 131072 column is history, not a recommendation.** Deleting `--batch` bought more slots
> (+1,947 at 163840) than lowering the context ever did (+557), so the trade no longer exists on this
> box. Read [07 §C2](07-corrections.md#c2-revert-max-context-to-163840)
> before acting on this table.

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

### The escape hatch: `"fit_max_tokens": true`

The error message itself tells you about it, and it is the reason the current box can keep a large
context without turning long prompts into 400s:

```json
{ "fit_max_tokens": true }
```

With it set, the **server** shortens `max_tokens` to the room left instead of rejecting the request.
Without it, a prompt that lands near the ceiling fails outright. Two consequences:

- The context limit stops being an availability cliff and becomes a degradation — you get fewer output
  tokens, not an error.
- It does **not** let you exceed the context with the prompt itself. A 200K prompt against a 160K
  context still fails; only the `max_tokens` part is negotiated.

This box has it on, together with `--max-context 163840`.

**Check your own distribution before copying this number:**

```bash
grep -oE 'prompt [0-9]+ tokens = ' engine.log | grep -oE '[0-9]+' | sort -n | tail -20
```
