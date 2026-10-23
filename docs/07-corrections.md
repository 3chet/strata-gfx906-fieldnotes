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
| C7 | 🔴 high | `--conversation-cache-mib` off — "production is one serial conversation" | The client **was** multiplexed (that half holds). The flag went **on, then off again within the hour** |
| C8 | 🟠 medium | The KV cache is ~3.87 GiB, so it is worth trading for slots | **≈0.47 GiB.** Measured. There is nothing to trade |
| C9 | 🟠 medium | `reading the prompt: 103,976 of 103,983` means it read 103,976 tokens | That is the **already-reused** count; 7 tokens were read |
| C10 | 🔴 high | A 23K A/B is enough to size the cache budget | **No.** 566 MiB parks in 6.7 s, 2.24 GiB takes 72 s. Snapshot cost is not linear |
| C11 | 🔴 high | The conversation cache can never be used: 22 MB/s ⇒ every resume trips the watchdog | **Superseded by 0.1.48**, which reserves the budget at startup: 1.5–4 GB/s, a 46K resume costs **3.2 s** instead of 70 s |
| C12 | 🔴 high | Decode is 38 tok/s, so the larger model is structurally slower | **38 is a cold-prefix artifact.** Real same-prefix sessions run **44–48**, up to 49. The harness was wrong, not the engine |
| C13 | 🟠 medium | The KV cache is 0.47 GiB, so there is nothing to trade for slots | **8.44 GiB** at 160K / `q4_0` / 48 layers. 0.47 was a ~16K-token slice misread as the whole |

Plus four gaps that would mislead a careful reader: [§G1](#g1-process-age-is-a-variance-input)
(process age), [§G2](#g2-cjk-prompt-tokens-per-character), [§G3](#g3-metrics-spec-is-not-argv-spec),
[§G4](#g4-a-bigger-ring-does-not-cost-slots).

**C11–C13 come from the 2026-10-23 engine upgrade (0.1.46 → 0.1.48.1).** They are not refinements of
C7/C8/C10 — they reverse their verdicts. If you took any configuration advice from this repository
between 2026-10-19 and 2026-10-22, read those three before anything else.

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

## C7. "Serial client" was a misreading of the traffic — yet the flag still came back off

**What I wrote.** In `docs/04` and `docs/10` §3: `--conversation-cache-mib` is genuinely effective but
**stays off**, because eighteen consecutive production requests had monotonically increasing
`in_tokens` (29,644 → … → 38,882) — "a serial single conversation appending to the same prefix every
turn", where parking buys nothing and costs 0.5–1.0 s.

**What is true.** The flag works — on a conversation of the size I tested:

```
--conversation-cache-mib 4096
--conversation-cache-min-tokens 20000
--conversation-cache-park-gain 2000
```

It went into production on that basis, and came back out an hour later (C10).

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

**Superseded the same day — by C10.** The traffic reading above is right: the client is multiplexed,
and parking does cut a 23K resume from 53.4 s to 14.4 s. What it did not survive is the *size* of the
sessions. On a 92K conversation the snapshot is 2.24 GiB, the write takes ~72 s, and the engine is
killed by its own 60 s stall watchdog in stage `parking`. The flags were removed within the hour.
C7 stands as the correction to "serial"; it is not a standing recommendation to enable the flag.

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

## C10. A 23K A/B is not enough to size the conversation cache

**What I wrote.** C7 above, and `docs/10` §4: the flag is worth 73% of a resume, so it belongs in
production at 4096 MiB, described as "~2 snapshots of a 100K session at ~20.4 KB/token".

**What is true.** 4096 MiB was the wrong unit of measure. The cost is not linear in snapshot size, and
the 23K session I tested sits on the cheap side of a cliff:

```
parked 23417 tokens in  6755.4 ms; bytes=593525912     #  566 MiB @ 84 MB/s
parked 78157 tokens in 61431.8 ms; bytes=1418474608    # 1.35 GiB @ 22 MB/s
```

Past roughly 600 MB the kernel starts evicting clean mmap'd pages to make room, so the write rate drops
**4×** — and the pages being evicted are the 42 GiB of experts that decode then has to re-read from
storage. The first production request after the change:

```
prompt 92628 tokens, 27 generated in 7423 ms (3.6 tok/s), hit rate 68.8%, 12,304 MB read (596,080 major faults)
```

against **36.3 tok/s / 95.2% / 364 MB** for a 78K prompt on the same box with clean RAM. Then two
`exit code -6`, both in stage `parking`.

**Two errors, not one.**

1. **I tested the cheap case and generalised from it.** 23K is where this flag looks free. The sessions
   this box actually runs are 60–100K, where the snapshot is 1.0–2.3 GiB.
2. **I trusted a budget check to bound a cost it does not bound.** `conversations.make_room(estimate,
   held)` and the resulting `skip parking (snapshot %zu MiB exceeds available budget)` in
   `src/program/generate.cpp` are correct code. But capacity was never the constraint: cutting the
   budget to 1536 MiB still admitted a 1,322 MiB snapshot, and that still took **61 s**. **The useful
   and the fatal snapshot sizes overlap, so no budget value separates them.**

**Corrected verdict.** Off, zero `conversation-cache` flags in `argv`. The flag is viable only where the
snapshot stays under ~600 MB (≈24K tokens), or on a box with enough RAM that a 2.24 GiB write does not
have to evict experts — 64 GB, which this box is not. Full measurements in `docs/10` §5, raw rows in
`results/r26`.

---

## C11. The conversation cache is not impossible — the version changed

**What I wrote.** C7, C10, `docs/10` §5 and the README verdict table: the conversation cache is
**off**, permanently, because parking is slow enough to trip the 60 s watchdog and "the useful and
the fatal snapshot sizes overlap, so no budget value separates them."

**What is true.** On 0.1.48 the same feature is the reason to upgrade.

| scenario | 0.1.45/0.1.46 | 0.1.48 |
|---|---|---|
| resume a 46K session after a 3K interruption | reused 0, 69.8 s | reused 46,192, **3.2 s** |
| switch between two long sessions | full re-read | 3.1–3.7 s, all hitting |
| park rate | 22 MB/s past ~600 MB | ~1.5–4.1 GB/s |
| capacity | hand-set `--conversation-cache-mib`, never right | 8192 MiB auto-sized from free RAM at startup, 4 sessions, `evictions=0` |

**Why the error happened.** Not a miscalculation — a version assumption. The 22 MB/s figure is a
genuine log line from 0.1.45, where the park competes with the kernel for pages and evicts the
mmap'd expert weights while writing. 0.1.48 **reserves its budget from measured free RAM at
startup**, so the park no longer fights the page cache. Same feature name, different failure
envelope.

A second, quieter error: the 0.1.46 log contains **no conversation-cache line at all**. On that
version the feature was never engaged, so the 22 MB/s sample was being used to indict something that
was never running.

**What it changes.** `--conversation-cache-mib` is gone from the configuration — do not set it, the
engine sizes the cache itself. And the behavioural rule in `docs/10` §6 ("never open two long
sessions") is now obsolete: on 0.1.48 both sessions stay resident.

Full measurements: [`13-engine-0.1.48.md`](13-engine-0.1.48.md) §2.3,
[`results/r31`](../results/r31-interleaved-session.csv).

---

## C12. Decode 38 was the harness, not the model

**What I wrote.** Across `docs/01`, `docs/04` and the README: "IQ3_S decodes at ~38 tok/s, the
smaller model did 44.3, so the upgrade costs 14% and that is structural — 45.7% expert coverage,
nothing can be tuned back."

**What is true.** Same binary, same 36 arguments, same pack:

| workload | prompt reuse | hit | decode |
|---|---|---|---|
| six unrelated prompts in rotation | **0%** | 0.88 | **38** |
| one 8K session, 6 appended turns | 98.7% | 0.964 | **47.6** (max 49.1) |
| one 55K session, 5 appended turns | 99.9% | 0.968 | **44.8** |

**Why the error happened.** The A/B harness rotates six unrelated prompts so that no arm can
benefit from a prefix another arm warmed. That is exactly right for *comparing flags* and exactly
wrong for *describing production*. Rotating costs 8 points of expert-cache hit rate and re-runs a
full prefill every round, which together cost about 13% of decode. The bias is systematic and
always in the same direction.

**What it changes.** Every absolute decode figure in r17/r18/r27/r28 is a **lower bound**. Their
relative verdicts stand — both arms were equally cold. The "the bigger model costs speed" conclusion
is withdrawn: steady state is equal or better. See [`12-multiturn-probe.md`](12-multiturn-probe.md).

---

## C13. The KV cache is 8.44 GiB, not 0.47 GiB

**What I wrote.** C8: "the KV cache is ≈0.47 GiB, measured; there is nothing to trade for slots."

**What is true.** Measured from the VRAM ledger at 160K context, `q4_0`, 48 layers:

| component | GiB |
|---|---|
| expert pool (11,240 slots × 1.879 MiB) | 20.62 |
| dense weights | 1.43 |
| **KV cache** | **8.44** |
| runtime / workspace | 0.56 |
| **total** | **31.05** of 34.33 available |

The 0.47 GiB is roughly **one 16K-token slice**, misread as the whole. KV is the second-largest
consumer, not a rounding error.

**What it changes.** C8's verdict ("nothing to trade") is reversed: there *is* something to trade.
The exchange rate is **10K of context ≈ 0.53 GiB ≈ 280 expert slots**, so dropping 160K → 100K
buys about +1,720 slots (+15%, coverage 45.7% → 52.7%). That trade was still declined — 130K
prefill measured at 713–716 tok/s, so long context is the machine's *best* operating range and
cancelling it to chase 280-slot increments is a bad deal — but it was declined **on evidence, not on
a wrong denominator**.

What does *not* change: `--kv-resident` is still hopeless (a long-context token reads ~3.3 GiB of KV
over PCIe ⇒ single-digit tok/s), `--kv k8v4` is still the wrong direction (816 B/cell vs 528),
`--kv-grow` still requires `!multi_gpu`.

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
