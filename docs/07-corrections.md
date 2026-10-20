# Corrections to earlier conclusions

This repository is a running record, not a paper. When a later measurement contradicts an earlier
verdict, the earlier verdict is wrong and this page says so.

**Read this page before copying any config block from this repository.** Two of the entries below are
not cosmetic: following the old `--batch 2` advice costs 13–16% of the expert cache, and following the
old `--max-context 131072` advice today costs slots rather than gaining them.

Every correction follows the same shape: **what I wrote → what is true → why the error happened →
evidence → what it changes.**

| # | Severity | What I wrote | What is true |
|---|---|---|---|
| C1 | 🔴 high | Keep `--batch 2` | **Delete it.** `parallel: 1`. Keeping it costs 13–16% of the slot count |
| C2 | 🔴 high | `--max-context 131072` adopted | **Reverted to 163840** a day before publication; the slot gain is gone |
| C3 | 🟠 medium | `auto:N` clamps to `32768 / 16384 / 8192` | Top rung resolves to **20992**, and `12288` silently becomes `8192` |
| C4 | 🟠 medium | chunk > 16384 rejected on *buffer cost* | Rejected on a **measured −25.4%**; the cause is the ring's coverage boundary |
| C5 | 🟡 low | `--prefill-head-alias` has 3 disqualifiers | **2** now — `--batch` is gone. Still refused |
| C6 | 🔴 high | Numbers presented as current | All absolutes are **0.1.44.1**; the box now runs **0.1.45** |
| C7 | 🔴 high | `--conversation-cache-mib` off — "production is one serial conversation" | **On, at 4096 MiB.** The client was multiplexed. Recovery 53.4 s → 14.4 s |
| C8 | 🟠 medium | The KV cache is ~3.87 GiB, so it is worth trading for slots | **≈0.47 GiB.** Measured. There is nothing to trade |
| C9 | 🟠 medium | `reading the prompt: 103,976 of 103,983` means it read 103,976 tokens | That is the **already-reused** count; 7 tokens were read |

Plus four gaps that would mislead a careful reader: [§G1](#g1-process-age-is-a-variance-input)
(process age), [§G2](#g2-cjk-prompt-tokens-per-character), [§G3](#g3-metrics-spec-is-not-argv-spec),
[§G4](#g4-a-bigger-ring-does-not-cost-slots).

---

## C1. Delete batch 2, do not keep it

**What I wrote.** `--batch 2` in the hardware table, in `docs/01`, in the "what to keep" block at the
end of `docs/04`, and in the expected-number hint of `docs/06`.

**What is true.** Production runs `"parallel": 1`. No `--batch` flag reaches the engine. Removing it
is the single largest measured gain in this repository:

| | with `--batch 2` | `parallel: 1` |
|---|---:|---:|
| expert slots | 11,897 | **13,529–13,767** (+13–16%) |
| expert cache | 18.8 GiB | **21.2–21.6 GiB** |
| decode | within noise | within noise |
| a second concurrent request | served in parallel | **waits ~6.0 s** |

**Why the error happened — and it was already visible in my own text.** §4.2 of
`docs/02-methodology.md` argues, correctly, that "if you send one request at a time, `--batch N`
costs VRAM and returns nothing", and then reports that production overlapped in **1.4%** and **0.1%**
of requests. That is the proof that `--batch 2` was pure cost. I used that measurement only to reject
`--batch 3` and never turned it on the value I was already running. The bigger of two costs was sitting
inside the evidence for the smaller one.

**What it changes.** The concurrency section of the old verdict stands — 2 is where this box peaks — but
the conclusion inverts: **if your workload does not overlap, `1` is not the conservative choice, it is
the faster one.** See [§09](09-concurrency.md) for what `parallel: 2` buys and costs when you *do*
overlap.

---

## C2. Revert max-context to 163840

**What I wrote.** `--max-context 163840 → 131072` marked ✅ **adopted**, with a VRAM ledger showing
11,820 → 12,377 slots (+557, +4.7%) and coverage 89.1% → 91.3%.

**What is true.** The box runs **163840** today, with `"fit_max_tokens": true`. Current ledger:

| | 163840, `--batch 2` (published) | **163840, `parallel: 1` (today)** |
|---|---:|---:|
| CUDA0 expert slots | 6,801 | **7,836** |
| CUDA1 expert slots | 5,019 | **5,931** |
| **total** | 11,820 | **13,767** |
| covered pairs / 24,576 | 13,900 (89.1%) | **13,952 (91.9%)** |
| K | 20 | **16** |

13,767 is **1,390 more** than the 12,377 that 131072 actually measured. The entire reason for
lowering the context — buy back slots — was overtaken by deleting `--batch`.

**Why the error happened.** The A/B was sound *in its own arms*: two runs each, deterministic
allocation, +557 slots attributable. What I got wrong was the tense. I published "adopted" as a standing
recommendation and did not re-check it against production before publishing. Config backups show the
163840 value was restored on **2026-10-16**, one day *before* the repository went public on 10-17. The
document was out of date on the day it was written.

I did not record the motive for that revert at the time, so I will not invent one. What I can show is
that today it is the better choice on its own merits, and that the older advice is no longer free: at
163840 today you get more slots *and* 33% more context.

**Also still true, and worth keeping.** Requests over the limit are rejected with HTTP 400, never
truncated. That part of `docs/01` stands. What was missing is the escape hatch: with
`"fit_max_tokens": true` in the model config, the *server* shortens `max_tokens` to the room left
instead of rejecting the request. Without it, a 160K-class prompt near the ceiling is an availability
bug; with it, the ceiling degrades gracefully. Set it.

**What it changes.** Do not lower `--max-context` to buy expert slots on a box that has already dropped
`--batch`. Check `expert_slots` in `/metrics` first — if you are already above ~13.5K, there is nothing
to buy back.

---

## C3. The chunk ladder tops out at 20992

**What I wrote.** "`auto:N` is clamped to **32768 / 16384 / 8192**."

**What is true.** The ladder is discrete and the values are not the ones you ask for:

| `--prefill` argument | chunk the engine actually uses |
|---|---:|
| `auto:32768` | **20992** |
| `auto:16384` | 16384 |
| `auto:12288` | **8192** |

The engine prints the resolved value at startup, one line per process:

```
strata serve: prompt chunk auto: 16384 tokens, a 384-slot ring
```

**Why the error happened.** I inferred the ladder from the argument values I had typed rather than
reading the resolved value out of the banner. `12288` was the tell: it is not a power of two, and it
resolved *down* to 8192 — a signal that the ladder is not the argument list. I read past it.

**What it changes.** This matters because 20992 is not a neutral "one step up": it is the −25.4% arm
(C4). Anyone who reads "clamps to 32768" and tries it is running the worst configuration measured here
while believing they are testing a bigger chunk. **Always read the resolved chunk from the banner, never
from `argv`.**

---

## C4. Why the bigger chunk loses

**What I wrote.** Rejected because going up "means double prompt buffers — the prompt path already
borrows 6.38 GiB of cache slots".

**What is true.** It is rejected, and the conclusion is right, but the reason is measurable:

| arm | `--prefill` | resolved chunk | median prefill | mean ± sd | span |
|---|---|---:|---:|---:|---:|
| A1b | `auto:16384` | 16384 | **689.1** | 685.0 ± 7.7 | 20.6 |
| A3 | `auto:12288` | 8192 | 690.2 | 689.6 ± 6.5 | 19.3 |
| A2 | `auto:32768` | 20992 | **521.4** | 510.8 ± 75.0 | **177.9** |

32,209-token prompts, n=7 per arm, every request with a fresh nonce so `reused = 0` everywhere.

- 8192 vs 16384: **+0.7%, t = 1.21** — not a difference.
- 20992 vs 16384: **−25.4%, t = −6.11 (df 6.1)** — and the spread tripled. That is not a slow arm, that
  is a stalled one.

**The mechanism, and it is the same coin as the ring.** The ring has a coverage boundary at 384 slots:
a 8192 chunk touches ≈192 distinct experts per layer, a 16384 chunk ≈384 (it fills the ring exactly),
and a 20992 chunk ≈491 — **over-subscribed, so a layer's experts get moved twice**, and the narrow x4
PCIe link on the second card amplifies it. This also explains why 8192 is not *better* even though it
is cheaper: it leaves half the ring unused and simply splits the same work into more chunks.

So the honest one-liner is: **`16384 × 384` is a matched pair.** Move either number alone and you lose.

**Why the error happened.** The old evidence was observational log-splitting with a Simpson's-paradox
composition problem, and I had correctly rejected it — then written a *cost* argument in its place
without measuring the cost. A dismissal deserves the same instrumentation as a claim.

**What it changes.** Nothing about the recommendation (`--prefill auto:16384` stays). Everything about
the reason, which now predicts where the cliff is instead of just asserting one exists.

---

## C5. Head-alias has two disqualifiers now

**What I wrote.** "This box violates **three**: 2-GPU layer split, `--batch 2`, and `short_read` at its
default 64."

**What is true.** `--batch` is gone (C1), so it violates **two** — `multi_gpu` and `short_read > 0` —
and startup still refuses with `it supports one GPU only`. The verdict is unchanged; the count is not.

**What it changes.** A reader on a layer split who has also dropped `--batch` now has one fewer thing to
fix before retrying this. It still will not start. Do not spend the afternoon.

---

## C6. Version labels on every absolute

**What I wrote.** "Engine: Strata 0.1.44.1, `build-714`", with baseline bands presented as current.

**What is true.** The engine is now **0.1.45** (`build-145`). I have **not** re-run r17/r18 or the
context A/B on 0.1.45 line by line, so I cannot tell you which of those verdicts moved. What I can tell
you is that the 0.1.45 numbers in this repository are labelled as such ([03 §10](03-readings.md)) and
that the old ones are not silently mixed in.

One concrete instance of version drift: `K` was 20 at 163840 in the old build and is **16** today
(predicted 57.0 ms per decode window, versus 68.4 ms then). K is a function of the profile ranking and
free VRAM, and I already warned about that in [02 §4.4](02-methodology.md#44-learned-state-is-an-input-on-the-next-boot) —
but a 20 → 16 swing between builds is larger than the noise I attributed to it.

**What it changes.** Treat the ✓/✗ verdicts as durable (they are about mechanisms) and the tok/s numbers
as build-specific (they are about this binary). If you are on 0.1.45, re-measure your own null before
chasing any percentage in this repository.

---

## C7. The conversation cache is on. "Serial client" was a misreading of the traffic

**What I wrote.** In `docs/04` and `docs/10` §3: `--conversation-cache-mib` is genuinely effective but
**stays off**, because eighteen consecutive production requests had monotonically increasing
`in_tokens` (29,644 → … → 38,882) — "a serial single conversation appending to the same prefix every
turn", where parking buys nothing and costs 0.5–1.0 s.

**What is true.** It is on:

```
--conversation-cache-mib 4096
--conversation-cache-min-tokens 20000
--conversation-cache-park-gain 2000
```

One 23,407-token conversation, a ~70-token interrupter to destroy the checkpoint, the conversation
again — four configurations, same script:

| step | cache off | 3072 / gain 2000 | 4096 / gain 0 | **4096 / gain 2000** |
|---|---:|---:|---:|---:|
| create | 39.5 s | 46.6 s | 38.0 s | 37.9 s |
| **resume after interrupter** | **53.4 s, `reused 0`** | 14.5 s | 14.7 s | **14.4 s** |
| **resume again** | **38.4 s, `reused 0`** | 14.9 s | 14.2 s | **15.3 s** |

**Why the error happened — two stacked mistakes.**

1. **"`in_tokens` only grows" does not mean "only one conversation exists."** A client with four
   conversations interleaved produces exactly the same monotonic sequence within each prefix. I sorted
   by time and concluded serial; I never grouped by prefix.
2. **The sample was one app, not the box.** The eighteen requests came from a single client. An hour
   of the box's real traffic had at least four prefixes: `reused = 86,897` recurring five times and
   `101,368` once, with the same 86K conversation resuming in **30.6 / 39.2 / 44.8 / 50.6 / 68.0 s**
   purely depending on which other session had spoken in between.

There is also a stale cost figure in the old note. "One or two requests took 29.5 s and 109 s" was
measured when `free` was ~350 MB; at 41 GB available the same configuration costs **2.7% decode** and
no reclaim storm. **A cost measured under memory pressure is not a property of the setting.**

**What it changes.** `docs/10` §3 is kept as history with a forward pointer; §4 carries the multiplexed
measurement and the production config. The "off" verdict is withdrawn. The durable lesson is narrower
than the flag: *a verdict about a cache is a verdict about a workload* — write the traffic shape next to
the verdict or it expires silently.

---

## C8. The KV cache is 0.47 GiB, not 3.87 GiB

**What I wrote.** "48 layers × 163,840 cells × 528 B/cell ≈ **3.87 GiB**, so lowering
`--max-context` buys ~475 / 949 / 1,431 slots at 131072 / 98304 / 65536."

**What is true.** Measured, from the engine's own startup line:

```
KV streaming: 40960 of 163840 cells per QSA layer in VRAM, the K/V in 0.35 GiB of pinned RAM
```

0.35 GiB for 40,960 of 163,840 cells ⇒ **≈0.47 GiB** for the whole reservation. **8× less than I
claimed.**

**Why the error happened.** I multiplied a per-cell byte figure by cells and by layers as if it scaled
that way across a layer split, and I never checked it against anything the engine printed. The one flag
that makes the engine state the number out loud — `--kv-resident` — was already on my rejected list, so
I never ran the experiment that would have corrected me.

**What it changes.** The "trade context for slots" table is dead as a live option: 163840 → 98304 frees
≈0.15 GiB, which is a few dozen slots, in exchange for rejecting every 100K session. The conclusion
in `docs/04`/`docs/06` ("do not lower the context") **survives, but the arithmetic behind it was wrong
by 8× and the stated reason was wrong** — the truth is not "you would gain slots you no longer need",
it is "there is almost nothing there to gain". See
[11 §4](11-long-context-and-verify-timeout.md#4-the-kv-cache-is-047-gib-not-387-gib--and-lowering---max-context-buys-nothing).

---

## C9. `reading the prompt: N of M` — N is reused, not read

**What I wrote.** "The prompt line shows 103,976 of 103,983 tokens processed in 18 s — that is
~3,800 tok/s, so a 104K prefill is fast on this box."

**What is true.** The counter counts tokens **served from the prefix cache** against the total. On that
request **7 tokens were read.** And a real 104K prefill, measured with a nonce so nothing could be
reused:

| | prompt tokens | reused | read | prompt time | rate |
|---|---:|---:|---:|---:|---:|
| cold | 104,548 | 0 | **104,548** | **194.4 s** | **535 tok/s** |
| resume | 104,551 | 98,304 | 6,247 | 18.7 s | — |

So the log line's apparent 3,800 tok/s and the engine's actual 535 tok/s differ by 7×, and the 18 s was
a **KV restore**, not a prefill.

**Why the error happened.** Same family as [G3](#g3-metrics-spec-is-not-argv-spec): I read a progress
display as a measurement. The line even has the shape of an I/O counter, which is what made it
plausible. The check that would have caught it takes one call: `reused` and `prompt_read` in
`/metrics`.

**What it changes.** It moved the diagnosis from "prefill is slow" to "restore plus expert refill is
slow", which is the correct one and points at a different fix. `docs/11` is built on it, and its first
section exists specifically so this misreading does not happen twice.

---

## G1. Process age is a variance input

`docs/02` tells you to build your null from two arms on two different restarts. It does not tell you
that **how long the process has been up** moves the variance, and that is what makes "same config, two
runs, a few percent apart" so common.

Two arms, byte-identical config, 32K prefill, n=7 each:

| | median | mean ± sd | span |
|---|---:|---:|---:|
| 40 h process | 685.6 | 677.9 ± **20.6** | 58.8 |
| fresh restart | 689.1 | 685.0 ± **7.7** | 20.6 |

The median moved 0.5%. The **spread tripled**. Candidate causes: the expert profile drifts as it keeps
learning, and VRAM fragments. I have not isolated which.

**Consequence for method:** an arm measured on a long-running process is not comparable to an arm
measured right after a restart, even at identical config — and the difference will not show up in the
median, only in the spread, which is exactly the number people skip. Restart before *both* arms, or
keep both arms on equal-age processes.

---

## G2. CJK prompt tokens per character

Every prompt length here is in tokens. If you write a fixture in Chinese, you need the right ratio, and
I had it wrong at first:

| | ratio | 53,000 Chinese characters gives |
|---|---:|---|
| what I assumed | 0.92 tok/char | ~48,800 tokens (way past 32K) |
| **measured** | **0.6 tok/char** | **~32,000 tokens** |

Getting this wrong is not a rounding error — it is a 50% miss, and it fails in the direction that makes
you think your prefill is slower than it is (bigger prompt, same wall clock, lower tok/s).

Worse: the ratio is **not stable** for text without whitespace. A stripped/reversed CJK passage
tokenised at roughly **1.9 tokens per character** in one of these runs — 3× the normal ratio — because
the tokeniser falls back to byte-level pieces. So:

> **Do not predict the token count. Read `usage.prompt_tokens` from the response and use that.**

That is also how the nonce trick in `scripts/measure_prefill.py` stays honest: it reports what the
server counted, not what you hoped.

---

## G3. metrics spec is not argv spec

Config says `--spec 4`. `/metrics` reports `spec: 6`. Both are correct: `--suffix-draft` (default 3)
grows the verify window, so the *effective* width is 6 while the *configured* value is 4.

This is the same family of mistake as C3 (reading argv instead of the resolved value), in the opposite
direction. The rule that covers both:

- **Verifying what you configured** → `/proc/<pid>/cmdline`.
- **Verifying what the engine is actually doing** → the startup banner and `/metrics`.
- Never use one to check the other.

---

## G4. A bigger ring does not cost slots

`docs/04` rejects a larger chunk partly because "the prompt path already borrows 6.38 GiB of cache
slots", which implies that prompt-side buffers compete with resident experts. For the **ring**, that
implication is false, and it is worth stating because it is the assumption that makes people skip the
cheapest win in this repository.

Raising `STRATA_PREFILL_RING` from the layer-split-forced 96 to 384, measured on the live service:

| | before | after |
|---|---:|---:|
| `expert_slots` | 13,767 | **13,767** |
| expert cache | 21,774 MiB | **21,774 MiB** |
| `vram_free_mib` | 878 | **878** |
| borrowed prompt buffer | 6.38 GiB | 7.00 GiB (during the request only) |

The ring is **borrowed for the duration of a prefill and handed back**. It is not residency. So
"free" is not an exaggeration here — see [08](08-prefill-rings-and-chunks.md) for the +3.8% it buys.

---

## What did *not* change

For credibility, the parts of this repository that the new measurements support:

- **`--prefill auto:16384`** — the value is right; only the reason was under-specified (C4).
- **`--spec 4 --spec-min-p 0.7`, `--lookup-chain` at default, `--suffix-draft` at default 3,
  `--mtp-q4` off** — all re-confirmed as "leave it" by later runs.
- **`--pool-workers 5`** — still the physical-core resolution on six cores.
- **The cold-start ramp and the pre-conditioning protocol** — reproduced again today, on prefill as well.
- **The restart hazard in `docs/05`** — the `ExecStop` that misses the engine child is still the most
  expensive trap on this box, and it caught me again during these runs.
- **"Two same-config arms are your null"** — the reason G1 exists. The protocol was right; the
  variable list was incomplete.

---

## How to read a verdict in this repository

```
✓ / ✗        durable — it is about a mechanism, and mechanisms do not change with a build
tok/s        build-specific — re-measure on your binary
"adopted"    a decision at a point in time, not a standing recommendation — check the date
```

If a number here is wrong, the per-request CSVs in `results/` are the ground truth. A disagreement
there is the most useful kind of report.
