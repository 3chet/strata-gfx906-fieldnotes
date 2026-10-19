# Readings

Every number a verdict in this repository rests on, in one place, with the comparison that matters
next to it. If you want to argue with a conclusion, this is the table to argue with.

---

## 1. The cold-start ramp

One arm, workload `count`, 128 output tokens, `temperature: 0`. The first five requests are the rise; the
last eight are the plateau.

| # | role | expert-cache hit | decode tok/s |
|---:|---|---:|---:|
| 1 | precondition | 84.0% | 33.5 |
| 2 | precondition | 89.2% | 38.9 |
| 3 | precondition | 91.2% | 43.3 |
| 4 | precondition | 96.1% | **51.2** |
| 5 | precondition | 96.7% | 49.3 |
| 6 | measured | 97.1% | 52.6 |
| 7 | measured | 97.2% | 53.5 |
| 8 | measured | 97.2% | 51.0 |
| 9 | measured | 97.2% | 51.2 |
| 10 | measured | 97.3% | 50.4 |
| 11 | measured | 95.9% | 53.5 |
| 12 | measured | 96.1% | 43.2 |
| 13 | measured | 96.9% | 51.5 |

**Ramp cost: 33.5 → ~51.5 = 35%.** And it restarts at each workload change within the same arm.

Sample 12 (43.2 tok/s at 96.1% hit) is why medians, not means: one outlier in eight, with no mechanism,
is noise.

### The hit rate is a marker, not a cause

Cross-tab over **3,204** requests paired with their own hit-rate line:

| hit-rate bucket | n | median decode tok/s |
|---|---:|---:|
| 0–85% | 516 | 20.10 |
| **85–90%** | 1,548 | **43.60** ← highest |
| 90–92% | 363 | 39.00 |
| 92–94% | 267 | 36.00 |
| 94–96% | 225 | 37.30 |
| 96–97% | 119 | 35.70 ← lower than the 85–90 bucket |
| 97–98% | 86 | 38.30 |
| 98–101% | 80 | 41.05 |

Not monotone. The hit rate also moves with prompt shape, so it cannot be the explanation — it is a
companion of "how many requests since the reset". Use it to check the plateau, not to justify a model.

---

## 2. Instrument resolution, measured

Same-config pairs, two restarts each, medians after pre-conditioning:

| config | workload | arm 1 | arm 2 | diff |
|---|---|---:|---:|---:|
| baseline | count | 52.85 | 53.15 | +0.57% |
| baseline | echo | 55.65 | 57.85 | **+3.88%** |
| baseline | prose | 42.60 | 43.10 | +1.17% |
| `--mtp-q4 all` | count | 52.05 | 51.75 | −0.58% |
| `--mtp-q4 all` | echo | 56.45 | 58.65 | +3.82% |
| `--mtp-q4 all` | prose | 41.40 | 43.60 | **+5.18%** |
| `--suffix-draft 0` | count | 51.85 | 51.80 | −0.10% |
| `--suffix-draft 0` | echo | 52.80 | 53.15 | +0.66% |
| `--suffix-draft 0` | prose | 43.15 | 42.90 | −0.58% |
| both | count | 49.65 | 49.55 | −0.20% |
| both | echo | 52.95 | 52.90 | −0.09% |
| both | prose | 40.90 | 40.90 | 0.00% |

**Resolution floor adopted: max(worst same-config pair for that workload, 2%).**
So: count 2.00%, echo 3.88%, prose 5.18%.

Consequence: **prose has no power to resolve anything under ~5%.** Of the three workloads, only `count`
and `echo` are decision-grade for small effects. Report this; do not quietly average prose in.

---

## 3. `--lookup-chain 3` vs default

Arm medians (8 measured samples each, 8 arms):

| arm | count | echo | prose |
|---|---:|---:|---:|
| A0 (default) | 51.35 | 56.45 | 43.05 |
| B1 (K=3) | 50.25 | 56.55 | 42.80 |
| B1b (K=3) | 51.25 | 56.75 | 43.10 |
| A0b (default) | 52.20 | 56.05 | 43.50 |

Drift-corrected effect (`y = a + b·t + c·group`):

| workload | b (drift/min) | c (effect) | 2·SE(c) | verdict |
|---|---:|---:|---:|---|
| count | −0.036 | −0.18 | ±1.33 | inside |
| echo | +0.096 | −0.39 | ±1.76 | inside |
| prose | +0.006 | +0.08 | ±0.44 | inside |

Mechanism (drafts per request / acceptance):

| workload | default | K=3 |
|---|---|---|
| count | 84.0 / 92.31% | 83.5 / 91.59% |
| echo | 142.5 / 90.52% | 143.0 / 90.07% |
| prose | 103.0 / 82.06% | **106.5 / 79.58%** |

---

## 4. `--suffix-draft 0` and `--mtp-q4 all` (2×2 factorial)

Sequential decode, effect vs the measured null:

| workload | `--mtp-q4 all` | `--suffix-draft 0` | both | null |
|---|---:|---:|---:|---:|
| count | −1.10 (−2.1%) | −1.17 (−2.2%) | **−3.40 (−6.4%)** | 2.0% |
| echo | +0.80 (+1.4%) | **−3.77 (−6.7%)** | **−3.83 (−6.7%)** | 3.9% |
| prose | −0.35 (−0.8%) | +0.18 (+0.4%) | −1.95 (−4.6%) | 5.2% |

Both negative effects stack; there is no complementarity.

Startup VRAM, verbatim:

```
default:       strata mtp: draft layer loaded, 912 MiB of VRAM (experts 675, dense 111)
--mtp-q4 all:  strata mtp: --mtp-q4: 10 projections as Q4_0 (37.3 MiB)
               strata mtp: draft layer loaded, 949 MiB of VRAM (experts 675, dense 111)
```

`experts 675, dense 111` identical on both lines → the Q4 copy is **additional**.

---

## 5. `--max-context` 163840 → 131072

Allocation (from startup banners, two runs each):

| | 163840 | 131072 |
|---|---:|---:|
| CUDA0 slot session | 0.63 GiB | 0.42 GiB |
| CUDA1 slot session | 0.87 GiB | 0.80 GiB |
| CUDA0 slots | 6,801 | 7,297 |
| CUDA1 slots | 5,019 | 5,080 |
| total | 11,820 | **12,377 (+557, +4.7%)** |
| coverage | 13,900 (89.1%) | 14,092 (91.3%) |
| K | 20 | 17 |
| predicted window | 68.4 ms | 58.5 ms |

Throughput effect (4-arm palindrome):

| workload | 163840 | 131072 | effect | null | verdict |
|---|---:|---:|---:|---:|---|
| count | 52.00 | 51.28 | −0.72 (−1.39%) | 2.50% | NOISE |
| echo | 58.62 | 58.05 | −0.58 (−0.98%) | 2.00% | NOISE |
| prose | 43.08 | 43.10 | +0.02 (+0.06%) | 2.00% | NOISE |

**Caveat, stated plainly:** `K` moved 20 → 17 in the same change, and the runs used different expert
profiles (frozen vs learned). The *slot* gain is deterministic and attributable; the `K` change is not.

Post-apply verification on the live 131072 service (no restart, 8 measured samples per workload):

| workload | median | MAD | prior band | verdict |
|---|---:|---:|---|---|
| count | 51.60 | 1.25 | 49.0–52.0 | in band |
| echo | 56.00 | 0.15 | 56.0–60.0 | in band |
| prose | 42.65 | 0.75 | 42.8–43.6 | in band (marginally low) |

---

## 6. Production concurrency

Slot events per process lifetime; a slot is held from `takes` to `gave back`.

| epoch | requests | slot events | moments with 2 held | share | peak |
|---|---:|---:|---:|---:|---:|
| ep1 | 44 | 6 | 2 | 4.5% | 2 |
| ep22 | 88 | 22 | 10 | 11.4% | 2 |
| ep30 | 26 | 21 | 12 | 46% | 2 |
| **ep40** (prod) | **585** | **15** | **8** | **1.4%** | **2** |
| **ep57** (prod) | **935** | **3** | **1** | **0.1%** | **2** |
| ep83 | 51 | 11 | 3 | 5.9% | 2 |
| experiment (batch 3) | 54 | 9 | 8 | — | **3** |

Peak 3 appears only where I ran `--batch 3` myself. Production never exceeded 2.

Duty cycle (request work ÷ wall clock):

| epoch | requests | work | wall | duty | idle |
|---|---:|---:|---:|---:|---:|
| ep40 | 585 | 2,520 s | 20,339 s | **12.4%** | 88% |
| ep57 | 935 | 10,979 s | 33,551 s | **32.7%** | 67% |

---

## 7. Prefill chunk as a natural experiment (and why it is not one)

| chunk | n | median prefill tok/s |
|---|---:|---:|
| 8192 | 168 | 473 |
| 16384 | 242 | 493 |
| 15872 | 6 | 437 |

Composition differs between groups — the 10–12K warm-up fixture is 32% of the 8192 group and 50% of the
16384 group. Length-matched:

| prompt | chunk 8192 | chunk 16384 | diff |
|---|---:|---:|---:|
| 10,764 | 428 | 415 | **−3.2%** |
| 15,506 | 550 | 554 | +0.9% |
| 7,403 | 475 | 485 | +1.9% |

Also a time confound: 8192 epochs are 10-13/14, 16384 epochs are 10-15 onward.

---

## 8. Log scope matters more than any of this

| scope | requests | reuse rate | zero-reuse waste |
|---|---:|---:|---:|
| all 184 process lifetimes | 3,104 | 92.13% | 4.95 h |
| production lifetimes only | 1,520 | **98.28%** | **0.26 h** |

Same file. The first row would have you "fixing" prefix reuse; the second says it is already fine.
Split by process lifetime, then by request shape.

---

## 9. Judge self-test (synthetic, known answer)

8 arms, `A B B A A B B A`, true effect **+2.00 tok/s**, true drift **+0.25 tok/s/min**, noise sd 1.0:

| workload | recovered drift | recovered effect | resolution |
|---|---:|---:|---:|
| count | 0.256 | +2.30 | ±0.35 |
| echo | 0.249 | +1.73 | ±0.50 |
| prose | 0.265 | +2.03 | ±0.35 |

Both recovered. Run this before trusting any fitting code.

---

## 10. Readings on 0.1.45 (2026-10-19)

A separate engine build and a separate configuration (`parallel: 1`, no `--batch`). **Nothing in this
section is comparable to §1–§8**, which are 0.1.44.1 with `--batch 2`. Raw samples:
`results/r19`–`r22`.

### 10.1 The prefill ring: 96 vs 384 (the one free win)

32,209-token fixture, fresh nonce per request, n=7 per arm:

| | ring 96 (layer-split default) | ring 384 | change |
|---|---:|---:|---:|
| prefill, 32K | 657.7 | **682.7** | **+3.8%** (median +4.4%) |
| prefill, 68K | not archived | not archived | +3.0% (noise ±15%, direction only) |
| decode | 42.4 | 42.15 → 42.6 | unchanged |
| `expert_slots` | 13,767 | 13,767 | identical |
| expert cache | 21,774 MiB | 21,774 MiB | identical |
| `vram_free_mib` | 878 | 878 | identical |
| borrowed prompt buffer | 6.38 GiB | 7.00 GiB | **during the request only** |

n=7/7 on the 32K arm, t ≈ 4.0. Ring **512 is worse**: −1.8% versus 384.

### 10.2 The chunk ladder (and why 20992 collapses)

Same fixture, same ring 384, only `--prefill` changed:

| arm | `--prefill` | **resolved** chunk | process age | median | mean ± sd | span |
|---|---|---|---:|---:|---:|---:|
| A1 | `auto:16384` | 16384 | 40 h | 685.6 | 677.9 ± 20.6 | 58.8 |
| **A1b** | `auto:16384` | **16384** | fresh | **689.1** | 685.0 ± 7.7 | 20.6 |
| A3 | `auto:12288` | **8192** | fresh | 690.2 | 689.6 ± 6.5 | 19.3 |
| A2 | `auto:32768` | **20992** | fresh | **521.4** | 510.8 ± 75.0 | **177.9** |

- `8192 vs 16384`: **+0.7%, t = 1.21** — not a difference.
- `20992 vs 16384`: **−25.4%, t = −6.11, df 6.1** — and the spread tripled.

A1 vs A1b is the same config on a 40 h process and a fresh one: **median 0.5% apart, sd 2.7× apart.**

### 10.3 `--pipeline-windows 2`: three arms, all rejected

8.3K prefill prompts, 256-token greedy decode, restart per arm:

| arm | config | decode | prefill 8.3K | spread | slots |
|---|---|---:|---:|---:|---:|
| **A** | `parallel: 1`, no pipeline | 42.0–44.3 | **491.7** | 1.4% | **13,767** |
| B | pipeline 2, draft on last card | 42.8 | **361.0** | 190% | 13,439 |
| C | pipeline 2 + draft on first card + subset vocab | 40.8 | 443.1 | 3.5% | 12,983 |

B is −26.6% prefill. C recovers prefill but loses decode (acceptance 63.8–73.9% vs A's 74–76%).
Note that A's 13,767 exists only because `--batch` had to be removed to test the pipeline at all —
that side effect was worth more than the feature.

### 10.4 `parallel: 1` vs `parallel: 2`

256-token greedy, 67-token prompt, restart per setting, steady medians:

| | single | two at once | three at once | slots |
|---|---:|---:|---:|---:|
| `parallel: 1` | **44.3–44.7** | 43.0 (queued, second waits 6.0 s) | — | 13,529–13,767 |
| `parallel: 2` | 40.9 (−8.3%) | **48.4 (+12.6%)** | 46.2 | 11,901 (−12%) |

Prefill does not parallelise: two 8.7K prompts took 19.1 s + 19.4 s = **39.5 s** total, i.e. strictly
serial.

### 10.5 Prefix reuse and checkpoint eviction

38,469-token conversation, `temperature: 0`:

| state | `reused` | `read` | prompt | wall |
|---|---:|---:|---:|---:|
| create | 0 | 38,469 | 60.5 s | 60.9 s |
| reuse × 4 | 38,464 | 5 | **72 ms** | **0.48–0.50 s** |
| after 60 s idle | 38,464 | 5 | 72 ms | 0.48 s |
| after a 1,986-token request | **0** | **38,469** | 55.0 s | 55.3 s |
| after a 68,895-token request | **0** | 38,469 | 57.4 s | 57.8 s |

**6 of 6 reuses landed in 0.48–0.50 s.** Evictor size does not matter: 1,986 tokens is sufficient.

### 10.6 `--conversation-cache-mib`: 768 fails, 1280 works

| budget | 38K snapshot | `parks` | `restores` | 38K conversation after an 888-token request |
|---:|---|---:|---:|---:|
| 768 | **783 MiB > budget → skipped** | 4 | **0** | 127.1 s (full re-read) |
| 1280 | 784 MiB | 4 | **2** | **0.99 s** (restored 38,464 tok in 87–100 ms) |

With the cache off, the equivalent measurement is §10.5: 55.0 s after a 1,986-token evictor. The
127.1 s figure above is longer than that because it was taken under heavier memory pressure, not
because the evictor was smaller — do not read the two as a size effect.

Cost: first park 33.7 s, then 0.5–1.0 s per turn, 1.08 GiB resident for two parked sessions.
After the 1.1 GB landed, the next two requests took 29.5 s and 109 s — a one-time reclaim storm, back
to 5.0 s afterwards.
