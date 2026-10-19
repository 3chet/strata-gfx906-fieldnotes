# Prefill: the ring, the chunk, and how to measure either

Prefill is 39–59% of engine time on this box ([01](01-hardware-and-baseline.md)), so it is the largest
single lever. This file is the one positive result in the repository that came from looking at *source
code and a startup banner* rather than at a config knob.

---

## 1. The finding: a layer split silently shrinks the ring to a quarter

A layer split does not only decide which card holds which layers. It also overrides the prefill ring:

```
ring_slots() priority:  STRATA_PREFILL_RING  >  g_ring_override  >  g_ring_budget  >  pinned_ring
                              (env)                (96 on a         (bytes)          (384 default)
                                                  layer split)
```

`g_ring_override = 96` exists to bound prompt-side VRAM when the cards are already tight. The env var
sits *above* it, so it can be raised back. `ring_cap()` allows up to 512.

The startup banner tells you which one won:

```
strata serve: prompt chunk auto: 16384 tokens, a 96-slot ring     # before
strata serve: prompt chunk auto: 16384 tokens, a 384-slot ring    # with STRATA_PREFILL_RING=384
```

**That number was 96 for weeks and nothing in the config said so.** It is not in the JSON, not in
`argv`, and not in `/metrics`. The only place it appears is that one line at startup.

### Measured

32,209-token prompts, n=7 per arm, fresh nonce per request, decode identical:

| | 96 slots | **384 slots** | |
|---|---:|---:|---|
| prefill, 32K | 657.7 | **682.7** | **+3.8%** (median +4.4%) |
| prefill, 68K | not archived | not archived | **+3.0%** (noise ±15%, direction only) |
| decode | 42.4 | 42.15 → 42.6 | unchanged |
| `expert_slots` | 13,767 | **13,767** | — |
| `vram_free_mib` | 878 | **878** | — |

n=7/7 on the 32K arm, t ≈ 4.0. **Cost: zero resident VRAM** — see
[07 §G4](07-corrections.md#g4-a-bigger-ring-does-not-cost-slots).

### 512 is worse than 384

```
ring 96  → 384 :  +3.8%
ring 384 → 512 :  −1.8%
```

The ring is not a "more is better" dial. 384 is the default the project ships for a reason, and a layer
split is what was hiding it.

**Apply it:**

```bash
"env": { "STRATA_PREFILL_RING": "384" }   # in the model JSON; restart to take effect
```

Rollback is deleting the key and restarting. There is no config file to repair.

---

## 2. The chunk and the ring are a matched pair

A ring slot holds one layer's routed experts for one prompt chunk. So the chunk size determines how
many slots a chunk *wants*, and the ring determines how many it gets:

| resolved chunk | distinct experts per layer | ring 384 | result |
|---:|---:|---|---|
| 8192 | ≈192 | half used | fine, just more chunks |
| **16384** | **≈384** | **exactly full** | **best measured** |
| 20992 | ≈491 | **over-subscribed** | **−25.4%**, spread ×3 |

Over-subscription means the same layer's experts are moved twice for one chunk, and the second card's
x4 PCIe link turns that into a stall. The numbers:

| arm | chunk | median | mean ± sd | span |
|---|---:|---:|---:|---:|
| A1b | 16384 | **689.1** | 685.0 ± 7.7 | 20.6 |
| A3 | 8192 | 690.2 | 689.6 ± 6.5 | 19.3 |
| A2 | 20992 | **521.4** | 510.8 ± 75.0 | **177.9** |

`8192 vs 16384`: **+0.7%, t = 1.21** — not a difference.
`20992 vs 16384`: **−25.4%, t = −6.11, df 6.1** — and the spread tripled.

This is why "just make the chunk bigger" fails, and why the failure is invisible in a short test: the
mean drops 25% but individual samples range from 405 to 583, so three samples can look like noise.

**Keep `--prefill auto:16384` with a 384-slot ring. Move neither alone.** (And note the ladder is
discrete — `auto:32768` resolves to 20992, not 32768. See [07 §C3](07-corrections.md#c3-the-chunk-ladder-tops-out-at-20992).)

---

## 3. How to measure prefill without fooling yourself

`scripts/measure_prefill.py` implements this. Five rules, each one learned by breaking it.

### 3.1 Every request needs a different prefix

The prefix cache is exact and aggressive. Send the same 32K prompt seven times and six of them reuse
38,464 of 38,469 tokens:

```
prompt 38469 tokens = 38464 reused + 5 read in 72 ms     # "0.07 s prefill"
```

That is a **reuse latency measurement**, not a prefill measurement. Put a non-zero nonce at the very
start of every request and assert `reused == 0` on all of them.

> This is also a hazard for your *production* service: a benchmark that sends a different prompt will
> evict the live conversation's checkpoint. See [10](10-prefix-cache.md).

### 3.2 Read `prompt_read / prompt_ms` from `/metrics`, not the DONE line

The DONE line reports `fresh_tokens / read_ms`, which is correct for a fresh request and nonsense for a
reused one. `/metrics` exposes both halves separately, so you can verify the request was actually fresh:

```
requests[0]: prompt_tokens, prompt_read, prompt_ms
```

### 3.3 Length in tokens, not characters

CJK converts at **0.6 tokens per character** (53,000 characters ≈ 32K tokens), and text without
whitespace can invert that to ~1.9. Build the fixture, send it, read `prompt_tokens`, then decide
whether it is the length you wanted. Do not compute it. ([07 §G2](07-corrections.md#g2-cjk-prompt-tokens-per-character))

### 3.4 Judge at 32K, watch 68K only for direction

| prompt | variance | use |
|---|---|---|
| 32K | 1–2% | **decision-grade** |
| 68K | ±15% | direction only; 2–3 samples cannot decide anything |

Long prompts need 90–130 s per sample, so an n=7 arm at 68K costs 15 minutes for a number that cannot
resolve a 4% effect. Spend the samples at 32K.

### 3.5 Discard the first sample

The first request after a restart pays for page-cache warm-up and hits the lowest expert-cache rate.
Same reason as decode ([02 §1](02-methodology.md#1-the-problem-a-5-request-cold-start-ramp-per-workload)),
different mechanism.

---

## 4. The configuration that survived

On 0.1.45, dual gfx906, layer split, no batch:

```
--layer-split auto
--prefill auto:16384              # do not move; 20992 is −25%
--spec 4 --spec-min-p 0.7
--max-context 163840              # with "fit_max_tokens": true
--kv q4_0
--pool-workers 5
--pcie-frac 0.3
--vram-reserve-mib 1024
--adapt-every 4 --expert-profile-save-every 3
env: STRATA_PREFILL_RING=384      # the one line that is not a flag
```

`--vram-reserve-mib 1024`: the engine's own `kVramSafeMib` on Linux is **512**, and the three stalls
already recorded here all had `vram_free` of 784 / 713 / 662 MiB — all *above* 512, so they were not
caused by reserve. 1024 keeps a margin without donating a slot; 1536 was pure loss.

---

## 5. What is still open

- **68K at ring 96 vs 384.** Direction agrees (+3.0%) but ±15% noise. Needs ~20 samples, i.e. ~45 min.
- **Whether 384 is optimal for a *different* chunk** — untested. The pair is measured, not explained from
  first principles, so another build may have a different boundary.
- **`--prefill auto:16384` with 32,768 ring** — impossible; `ring_cap()` is 512, and 512 measured worse.
