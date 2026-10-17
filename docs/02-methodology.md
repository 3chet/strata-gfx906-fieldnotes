# Methodology: how to measure this thing without fooling yourself

This is the most useful file in the repository. Everything else is data this method produced.

---

## 1. The problem: a ~5-request cold-start ramp, per workload

Every restart, and **every time you switch workload**, decode throughput climbs over roughly five
requests before it plateaus. Real sequence from one arm (workload `count`, 128 tokens out,
`temperature: 0`):

| sample | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| expert-cache hit rate | 84.0% | 89.2% | 91.2% | 96.1% | 96.7% | 97.1% | 97.2% | 97.2% |
| decode tok/s | **33.5** | 38.9 | 43.3 | 51.2 | 49.3 | 52.6 | 53.5 | 51.0 |

Two things to notice:

1. **Sample 1 is 36% below the plateau.** Any average that includes it is biased low.
2. **The ramp restarts when you change workload.** In the same arm, switching to `echo` dropped back
   to 38–40 tok/s and climbed again. It is a per-workload effect, not a one-time warm-up.

> **Correction I had to make to my own notes.** I first wrote that "decode throughput is governed by
> the expert-cache hit rate". A global cross-tab over 3,204 requests says otherwise — it is *not*
> monotone (the 85–90% bucket has the highest median, 43.6 tok/s; 96–97% has 35.7). The hit rate also
> moves with prompt shape. **The hit rate is a companion marker of "how many requests since the reset",
> not the cause.** It is still useful as a plateau *indicator*; it is not an explanation.

### What to do about it

Pre-condition before measuring. Five discarded requests per workload is enough on this box; check the
hit-rate column to confirm you are actually on the plateau before trusting any sample.

---

## 2. The second problem: the instrument may be blunter than the effect

My first real A/B used 4 arms, 5 measured samples per arm, one discarded. The verdict was "no
difference". The reasoning behind it was wrong:

| | value |
|---|---|
| Between-arm difference | −0.71% … −6.16% |
| **Same config, two restarts** (the null) | **6.98%** (count), 3.35% (echo), 1.88% (prose) |
| Within-arm full-range spread | 32.5% … 43.9% |

The within-arm spread was **40× the effect**. A scale that cannot resolve 7% of its own drift cannot
weigh a 1% change. Saying "no effect" from that run would have been an accident, not a finding.

### The rule

> **Never report "no difference" without first computing your resolution.**
> If you cannot state "I can see changes larger than X%", you have not measured anything.

---

## 3. A protocol that survives all of the above

### 3.1 Arms

- **Two arms per configuration, identical config, on different restarts.** Their difference *is* your
  measured null. Do not estimate it from sample variance — sample variance will be too optimistic,
  because samples inside one arm are not independent.
- **Interleave the arms in a palindrome** so drift cancels: `A B B A` for two configs,
  `A B B A A B B A` if you want the drift slope to be estimable.

### 3.2 Per arm, per workload

1. Send **5 requests and discard them** (pre-conditioning).
2. Send **8 requests and keep them**.
3. For every sample record: `reused`, `generated`, `decode_ms`, `tok/s`, `drafts accepted A of B`,
   and the **expert-cache hit rate**.
4. Use the **median**, not the mean. Single outliers are real (one sample in eight can be 15% low);
   the median ignores them, MAD describes them.

### 3.3 Judging

Fit, per workload:

```
y = a + b·t + c·group
```

- `y` = the arm's plateau level (median of its measured samples)
- `t` = the arm's wall-clock start, centred — **thermal/time drift**
- `group` = 0 for baseline, 1 for the config under test
- `b` = drift per minute, `c` = the effect you want
- **Resolution = 2·SE(c)**, and SE(c) comes from the residual variance with the same-config pairs as
  the sanity check.

**Verdict rule:** SIGNAL only when `|c| > 2·SE(c)` **and** every workload agrees in sign.

If `2·SE(c)` is much smaller than the same-config difference, trust the **larger** number. A model that
claims ±1.5% while the machine reproduces itself to ±4% is lying to you.

### 3.4 Sanity-check the judge on synthetic data first

Before trusting a fitting routine, feed it a known answer. I generated 8 arms with a **true effect of
+2.00 tok/s** buried under **+0.25 tok/s/min drift** and noise sd = 1.0. The judge recovered
`b = 0.249–0.265`, `c = +1.73…+2.30`, resolution ±0.35–0.50. Only then was it used on real data.

If your tool cannot recover a known effect, every verdict it produces is worthless.

---

## 4. Traps specific to this engine

### 4.1 The engine's own log mixes workloads you did not send

The engine log for this box spans 221 process lifetimes, and most of them are **my own A/B runs**.
Aggregating "all requests" mixes benchmark fixtures with production traffic. On this box:

| Scope | Requests | Reuse rate | Zero-reuse waste |
|---|---|---|---|
| All 184 epochs | 3,104 | 92.13% | 4.95 h |
| **Production epochs only** | 1,520 | **98.28%** | **0.26 h** |

Same log, same code path, a 19× difference in the headline. **Split by process lifetime first**, and
even then be careful: warm-up harnesses run inside production lifetimes too. The reliable separator is
*request shape* (a fixed token count recurring with zero reuse is a fixture, not a user).

### 4.2 `--batch` only exists while requests overlap

If you send one request at a time, `--batch N` costs VRAM and returns nothing. On this box the
production peak concurrency was **2**, reached in 8 moments out of 585 requests (1.4%), and 67–88% of
wall time the engine was idle. Measure overlap before tuning for it.

Detection: the engine prints `strata batch: slot N takes … tokens` / `… gave back …`. A slot held from
`takes` to `gave back` is a request in flight; two held simultaneously is real overlap.

### 4.3 Greedy output is not reproducible across restarts

Even with a byte-identical config, three restarts produced three different text fingerprints, and the
same arm produced 4–8 different fingerprints on one prompt. GPU reduction order, batch-slot history and
the learned profile initial value all move.

**Consequence:** never compare output text across restarts. If a setting might change the output, either
test it within one process via a per-request key, or accept that you cannot judge it this way.

### 4.4 `learned` state is an input on the next boot

`expert_profile_save` points at a file the engine rewrites every 3 minutes. The startup code silently
substitutes it for the configured `--expert-profile` when the shape matches. Every arm then starts from
a different expert ranking.

Worse, the **layer-split search reads that ranking**:

```
--expert-profile <frozen>            → K = 20, consistently (8/8 starts)
--expert-profile <learned>           → K ∈ {11, 15, 16, 17, 18}, predicted 59.6 ↔ 68.4 ms
```

A 15% swing in predicted decode cost, caused by a file you were not thinking about. **Freeze the profile
before any VRAM-sensitive comparison**, and verify from the running process's own `cmdline`, not the
config.

---

## 5. Checklist

```
[ ] pre-conditioned (>=5 discarded requests) *per workload*
[ ] hit rate confirms the plateau before keeping any sample
[ ] two arms per config, same md5, different restarts
[ ] palindromic arm order
[ ] medians + MAD, not means
[ ] drift fitted, not averaged
[ ] resolution computed and stated
[ ] judge validated on synthetic data with a known effect
[ ] profile frozen; verified from /proc/<pid>/cmdline
[ ] config md5 verified before and after
[ ] "no difference" only reported with a number for "how small a difference I could have seen"
```
