# The prefix cache, and why "reuse is sometimes 95 s" was the wrong diagnosis

A 38K conversation that normally resumes in **0.48 s** sometimes took **95 s**. The obvious reading —
"checkpoint restore is unstable" — is wrong. There is no restore happening in that case. This file
separates the two things that were being called one thing.

---

## 1. Reuse is not slow. Reuse is either there or it is not.

Same 38,469-token prompt, sent repeatedly, `temperature: 0`:

| step | `reused` | `read` | prompt time | wall |
|---|---:|---:|---:|---:|
| create | 0 | 38,469 | 60.5 s | 60.9 s |
| reuse × 4, back to back | 38,464 | 5 | **72 ms** | **0.48–0.50 s** |
| after 60 s idle | 38,464 | 5 | 72 ms | **0.48 s** |
| after an unrelated prompt | **0** | 38,469 | 56.6 s | 57.1 s |
| reuse again | 38,464 | 5 | 72 ms | 0.48 s |

**6 of 6 reuse attempts landed in 0.48–0.50 s.** Not one was slow. The restore path is stable to
within 4%.

The variance came entirely from the two states, not from the speed of either. When `reused = 0` you are
not watching a slow restore — you are watching a **full re-read**, and a full re-read of 38K is 55 s.

> **Why the original note was wrong.** It compared "3.0 s" against "95 s" as if they were the same
> operation. 3.0 s was a reuse plus a short decode; 95 s was a cold re-read after the checkpoint had been
> discarded. Two populations, one label — and a median taken across them describes neither.

---

## 2. Any other prompt discards the checkpoint — including your benchmark

`generate.cpp:11134-11137`:

```cpp
checks.erase(std::remove_if(checks.begin(), checks.end(),
    [&](const Checkpoint& c) {
        return c.ids.size() > resume || !starts_with(c.ids, c.imgs);
    }), checks.end());
```

Not a partial invalidation. Anything that is not a prefix of the incoming prompt is **erased**. Tested
with evictors of four sizes:

| evictor prompt | its cost | the 38K conversation afterwards |
|---:|---:|---:|
| 1,986 tok | 7.8 s | `reused = 0`, 55.0 s |
| 15,366 tok | 28.2 s | `reused = 0`, 56.6 s |
| 38,305 tok | 55.5 s | `reused = 0`, 56.6 s |
| 68,895 tok | 116.6 s | `reused = 0`, 57.4 s |

**A 1,986-token request is enough.** Size is irrelevant; the checkpoint is all-or-nothing.

`--prompt-cache` (default 6 slots, ~118 MB each) does not save you: those are checkpoints *within* one
conversation, not a cache of several conversations.

### The self-inflicted version

If you benchmark against a live service, **your benchmark prompt is the evictor**. That is very likely
where the original "sometimes 95 s" observation came from: an A/B run between two production requests,
followed by a cold read attributed to the production request.

Check before you blame the engine:

```bash
grep -a 'reused' engine.log | grep -av '= 0 reused' | tail -20
```

If every line is a small `read` count, reuse is fine. If you see `= 0 reused` on a prompt that has been
sent before, something evicted it.

---

## 3. The fix, and why it was off for two days

`--conversation-cache-mib` (default **0 = off**) parks a session's checkpoint in host RAM instead of
destroying it, and restores it when that conversation comes back.

> **This section is history. Read [§4](#4-the-measurement-that-argued-for-turning-it-on) and
> [§5](#5-rolled-back-within-the-hour-a-92k-session-takes-72-s-to-park) before copying anything from
> it.** The "off" verdict below was correct for a client that runs one conversation at a time. It did
> not survive a client that keeps three or four alive: on that workload the flag went on, cut recovery
> time by 73%, and was then **removed again within the hour** — because those conversations are 90K,
> and a snapshot that size takes longer to park than the stall watchdog allows. **The flag is off.**

### 768 MiB is not enough — and the engine says why

```
conversation cache: skip parking (snapshot 783 MiB exceeds available budget)
```

Metrics at that budget: `parks = 4, restores = 0`. It parked the small requests and dropped the 38K one
every time. A budget that is 98% of what you need behaves exactly like a budget of zero.

Snapshot size is predictable:

| | |
|---|---:|
| fixed floor (even a 74-token session) | ≈226 MiB |
| per 1,000 prompt tokens | ≈15 MiB |
| **38K session** | **784 MiB** (measured `822,056,944 B`) |
| 68K session | ≈1.25 GB |

### 1280 MiB works

```
conversation cache: restored 38464 tokens (checkpoint) in 100.1 ms
conversation cache: restored 38464 tokens (checkpoint) in  87.2 ms
```

| scenario | without | with |
|---|---:|---:|
| 38K conversation after an 888-token request | **127.1 s** | **0.99 s** |
| 38K conversation after a 1,696-token request | **63.9 s** | **0.56 s** |

~130× on the case it is designed for. The flag is genuinely effective. It is still off in production.

### The cost, measured

| item | |
|---|---|
| first park | **33.7 s** (materialising 784 MiB for the first time) |
| every later park | 0.5–1.0 s |
| `--conversation-cache-park-gain` default | **0 = write a snapshot every turn**, even in a serial session |
| resident cost | 1.1 GB with two sessions parked |
| side effect | 1.1 GB against `free` of ~350 MB forces the kernel to reclaim expert page cache; the next one or two requests took **29.5 s** and **109 s**, then returned to 5.0 s |

That last row is a one-time reclaim storm, not a permanent regression — but on a 47 GB box it is real,
and it is why the setting is paired with "buy RAM" rather than "turn it on".

### Why production did not use it, on 2026-10-18

Eighteen consecutive production requests had **monotonically increasing** `in_tokens`
(29,644 → … → 38,882). That is a serial single conversation appending to the same prefix every turn.

- Benefit of parking: **zero** — nothing else ever competes for the checkpoint.
- Cost per turn: **0.5–1.0 s** plus 1.1 GB.
- Net: negative.

Removed. `conversation_cache.enabled = false`, zero `conversation-cache` flags in `argv`.

That was a correct reading of the traffic, and a wrong reading of the *client*. The evidence was
"every request's `in_tokens` goes up", which is true of a serial conversation **and also true of a
multiplexed client whose conversations are simply interleaved**. Two days later the same box showed
four conversations at 100K, 107K, 116K and 132K taking turns, and the flag went back on — see §4.

The failure mode is worth naming, because it is not about this flag: **"the prefix only ever grows"
is not the same claim as "only one prefix exists".** Check how many distinct reuse start points appear
in an hour before you decide a client is serial:

```bash
grep -a 'strata serve: prompt ' engine.log | sed 's/.* = \([0-9]*\) reused.*/\1/' | sort -n | uniq -c
```

One or two values ⇒ serial. Five or more, spread over the range ⇒ multiplexed.

### When to turn it on

```bash
--conversation-cache-mib 1024
--conversation-cache-slots 2
--conversation-cache-min-tokens 4096
--conversation-cache-park-gain 8192      # do not snapshot every turn
```

Turn it on when **two conversations with different prefixes** alternate — two client sessions, a
sub-agent with its own context, or an A/B harness running beside production. That was the case
production turned out to be in (§4), not the serial case §3 was written for.

> ⛔ **But only while the snapshot stays under ~600 MB (≈24K tokens).** Past that the write rate falls
> from 84 MB/s to 22 MB/s, the write no longer fits inside the 60 s stall watchdog, and the pages it
> evicts are the experts that decode is about to need. A 92K session takes **72 s** and kills the
> engine — which is exactly what happened to this flag in production
> ([§5](#5-rolled-back-within-the-hour-a-92k-session-takes-72-s-to-park)). The `-mib` budget cannot
> express this limit, because the useful and the fatal snapshot sizes overlap.
>
> After a 64 GB upgrade the ratio changes and the flag may become viable again, but that is a
> **prediction, not a measurement** — see
> [09 §3](09-concurrency.md#3-64-gb-what-it-buys-and-what-it-does-not).

### One warning about the guard rail

`--conversation-cache-min-free-mib` defaults to **2560** and is meant to stop parking when memory is
tight. On this box `MemAvailable` reports **41 GB** while `free` is 350 MB — because mmap'd clean pages
count as available. **So the guard never fires.** Only the `-mib` budget actually bounds it. Do not rely
on the min-free check to protect you.

---

## 4. The measurement that argued for turning it on

> **Also history — read [§5](#5-rolled-back-within-the-hour-a-92k-session-takes-72-s-to-park).** The
> A/B below is correct and is what put the flag into production. It tested a **23K** session, whose
> snapshot is 566 MB and parks in 6.7 s. Production sessions were **92K**, whose snapshot is 2.24 GiB
> and parks in ~72 s. The measurement was sound; the generalisation from it was not.

§3 checked `in_tokens` and concluded "serial". It never counted prefixes. One hour of real traffic on
the same box, grouped by reuse start point:

| reuse starts at | read | prompt time |
|---:|---:|---:|
| **101,368** | 2,595 | **9.1 s** |
| **86,897** | 14,478 | 30.6 s |
| **86,897** | 16,781 | 39.2 s |
| **86,897** | 20,160 | **68.0 s** |

`86,897` recurred **five times** in that hour while `101,368` appeared once — three of the five are
shown above with their read counts (the other two took 44.8 s and 50.6 s). At least four conversations
were sharing a common prefix and taking turns. Every switch between them erased the others' checkpoints
(§2), so the same 86K conversation paid 30–68 s depending on how many other sessions had spoken in
between. That is the variance users report as "prefill is randomly slow", and it is precisely the case
the flag exists for.

### The A/B — four configurations, one script, one session

One 23,407-token conversation, then a one-sentence interrupter (~70 tokens) to destroy its checkpoint,
then the same conversation again. Same script, same prompt, four engine configurations:

| step | cache off | 3072 MiB, gain 2000 | 4096 MiB, gain **0** | 4096 MiB, gain 2000 |
|---|---:|---:|---:|---:|
| A1 create | 39.5 s, `reused 0` | 46.6 s | 38.0 s | 37.9 s |
| **A2 after interrupter** | **53.4 s, `reused 0`** | 14.5 s, `reused 16,384` | 14.7 s | **14.4 s** |
| **A3 after interrupter again** | **38.4 s, `reused 0`** | 14.9 s, `reused 16,384` | 14.2 s | 15.3 s |

Two things this establishes that §3 could not:

1. **The "off" column is the proof, not a control.** `reused = 0` on a prompt that had just been
   served is only possible because a ~70-token request erased it. The flag's entire value is keeping
   that checkpoint alive.
2. **`park-gain 0` changes nothing.** Snapshotting on every turn bought 0.3 s and cost disk churn, so
   the conservative `2000` is what production runs.

### What the flag cannot do — two hard limits

Both were found by trying to break them, not by reading the docs.

**Limit 1: restore granularity is capped at 16,384.** The conversation was 23,417 tokens; the engine
restored 16,384 of them:

```
conversation cache: parked 23417 tokens in 6755.4 ms; parked=1
conversation cache: restored 16384 tokens (checkpoint) in 84.6 ms
```

16,384 is the prefill chunk boundary, so the parked snapshot can only be re-entered at chunk edges.
`park-gain 0` did not lift it. **Consequence, and it is a happy one:** the ceiling is fixed, so the
*surviving fraction* grows with session length. A 23K session recovers 70%; a 100K session recovers
98,304 — **98%**, leaving ~1,700 tokens (≈3.5 s) to recompute. Short sessions lose most of the benefit,
long ones lose almost none.

> **But read §5 before acting on that.** It is arithmetic about the restore *ceiling*, and it assumes
> the park completed. At 100K the park does not complete: the snapshot is 2.24 GiB and the write takes
> ~72 s, past the watchdog. The sessions that would benefit most are the ones that cannot be parked.

**Limit 2: an interrupter empties the pool, and it is not eviction.** The log sequence is
`parked=1` → interrupter → `parked=0`, with `evictions = 0` throughout. Capacity was never the
constraint (4,096 MiB holds roughly two 100K snapshots at ~20.4 KB/token). The pool is dropped when
the conversation it belongs to is no longer the active one, and there is no flag for that. This is why
A2/A3 recover 16,384 and not 23,417 — the 16K checkpoint survives in the normal cache, the parked
snapshot does not.

So the honest description is: **the flag converts a 53 s cold read into a 14 s read from the last
chunk boundary.** Not into 0.5 s. The 87–100 ms restores quoted in §3 are real, but they come from the
*normal* checkpoint cache on a session that was never interrupted, and they are not what an interleaved
client gets.

### The cost, measured on the same box

| item | before | after |
|---|---:|---:|
| decode, 256-token prose, median of last 3 | 43.8 tok/s | **42.6 tok/s (−2.7%)** |
| expert-cache hit rate | 0.99 | 0.99 |
| `expert_slots` | 13,522 | 13,523 |
| `vram_free_mib` | 1,230 | 1,230 |
| host RAM used / available | 5.0 / 41 GB | 5.7 / 41 GB |
| engine `VmSwap` | — | 255 MB |

Two costs that only show up under load:

- **First park is expensive**: 6.7–10.9 s while it materialises ~565 MB. Later parks are **314 ms**.
- **The request right after a park is starved**: a ~70-token request that normally takes 0.87 s took
  **12–18 s**. In a real client there is a gap between turns, so this rarely lands; in a loop it is
  the dominant cost.

**Net on a full round trip** (create + interrupt + resume): 93.8 s → 74.0 s, **−21%**. The recovery
segment alone is 53.4 → 14.4 s, **−73%**. A 2.7% decode tax for that is the cheapest trade in this
repository.

> **`--conversation-cache-min-free-mib` still does not protect you** (§3). On this box `MemAvailable`
> reads 41 GB while `free` reads hundreds of MB, because mmap'd clean pages count as available, so the
> guard never fires. Only the `-mib` budget bounds the pool. Size it deliberately.

### The configuration that ran — for about one hour

```
--conversation-cache-mib 4096          # ~2 snapshots of a 100K session at ~20.4 KB/token
--conversation-cache-min-tokens 20000  # short requests must not occupy a slot
--conversation-cache-park-gain 2000    # only re-snapshot after 2K of growth
```

`min-tokens 20000` kept 70-token requests out of the pool, exactly as intended. It did nothing about
the sessions that *are* 92K — which are the ones this box actually runs. See §5.

---

## 5. Rolled back within the hour: a 92K session takes 72 s to park

The first real request after §4 went live:

```
prompt 92628 tokens = 0 reused + 92628 read in 159516 ms (580.7 tok/s), 27 generated in 7423 ms (3.6 tok/s)
decode expert cache hit rate: 68.8% (6317 hits / 9186 lookups)
file tier I/O: the OS read 12304.4 MB from storage (596080 major faults) for 290866.2 MB of expert reads
```

**27 tokens generated in 7.4 s (3.6 tok/s), inside a request that took 6 min 15 s end to end**, against
a 43.8 tok/s baseline. The 27 tokens are not a truncation — the turn ended naturally; the slowness is
elsewhere. Then two engine suicides, eight minutes apart:

```
no progress for 60 s during a request (request: parking the previous conversation -1) - stopping the engine (issue #29)
stall report: 0 layers served; expert pool 18/18 done; 5/5 workers sleeping; host idle 66 s
```

`exit code -6`. **The engine did not die while generating — it died while parking.** The stall stage
is named `parking`, and `0 layers served` says the request never began: it was queued behind the
previous conversation's snapshot write.

### The decisive comparison

Same box, same binary, two sessions 15K apart — pool holding a snapshot in one case, not in the other:

| | prompt | prefill | decode | hit rate | disk read |
|---|---:|---:|---:|---:|---:|
| production, pool loaded | 92,628 | 159.5 s | **3.6 tok/s** | 68.8% | 12,304 MB |
| same box, clean RAM | 78,157 | 113.7 s (687 tok/s) | **36.3 tok/s** | 95.2% | **364 MB** |

The prompt lengths differ, so this is **not** a clean one-variable A/B and I am not going to present it
as one. What it establishes is narrower and sufficient: a session of this size on this box is **not
inherently** a 3.6 tok/s workload. The causal link to the pool rests on the mechanism — 68.8% hit and
12.3 GB of re-reads against 95.2% and 364 MB — plus the fact that both deaths happened in stage
`parking`. "Long context is slow" is the wrong reading. The chain, in three steps:

1. A 92K prefill borrows **9,067 expert slots** (`5032 CUDA0 + 4035 CUDA1`) — 67% of the 13,523 total.
   Returning them evicts the pages that decode is about to need.
2. Decode re-reads experts from storage: 12.3 GB, 596,080 major faults.
3. **Why those pages were not in RAM:** the parked snapshot (2.24 GiB) plus 2.9 GB of swap pushed the
   42 GiB of mmap'd experts out of page cache. The pool is not merely slow to write — it is what makes
   the *next* request slow to run.

Then it closes into a loop: park 2.24 GiB → stall past 60 s → watchdog kills the engine → pool cleared
→ next turn `reused 0` and a full re-read → 9,067 slots borrowed again → 3.6 tok/s → park again.

### The number that matters: 24.75 KB per token, and 22 MB/s

Two parks on this box, one just below the cliff and one past it:

```
parked 23417 tokens in  6755.4 ms; bytes=593525912     #  566 MiB @ 84 MB/s — free pages available
parked 78157 tokens in 61431.8 ms; bytes=1418474608    # 1.35 GiB @ 22 MB/s — now reclaiming
```

The unit cost is stable at **24.75 KB/token**; the *rate* is not. Below roughly 600 MB the write runs at
84 MB/s and leaves the expert pages alone. Above it, throughput falls to **22 MB/s**, because the kernel
is now evicting clean mmap'd pages to make room. At 22 MB/s a 92,628-token session (2,239 MiB, from the
same unit cost) needs **≈72 s** — longer than the 60 s stall watchdog, so the engine cannot survive it.

And the park is not free even when it succeeds: it is a **pre-request action for the next request**. A
`1+1` prompt that normally returns in 0.87 s was blocked for **62.8 s** behind the snapshot write.

### Corrected rule

> **The safety of this flag is a ratio — snapshot size ÷ free RAM — not a token count.**

| session | snapshot | park | verdict |
|---:|---:|---:|---|
| 23,417 | 566 MiB | 6.7 s @ 84 MB/s | works; −73% resume |
| 78,157 | 1.35 GiB | **61.4 s @ 22 MB/s** | already fatal — the watchdog is 60 s |
| 92,628 | 2.24 GiB | **≈72 s** (derived) | fatal |

So the flag is safe only where the snapshot stays under **~600 MB, i.e. roughly 24K tokens**. Above
that it is both slower to write and more expensive to run afterwards, and the crossover is sharp rather
than gradual — which is why a 23K test could not see it.

### The `-mib` budget is a real guard, but not the guard you need

The engine does refuse oversized snapshots. `src/program/generate.cpp` has

```
conversation cache: skip parking (snapshot %zu MiB exceeds available budget)
```

gated on `conversations.make_room(estimate, held)`. The check is correct; the calibration is not.
Dropping the budget to 1536 MiB still admitted a 78K snapshot at 1,322 MiB — comfortably under budget
and still 61 s to write. **Any budget large enough to let a working session park is already large
enough to kill the engine**, because the useful size and the fatal size overlap. That is why the
answer is "off", not "re-tuned".

### Verdict: off

Rolled back to zero `conversation-cache` flags. Verified after restart:

| measurement | pool loaded | rolled back |
|---|---:|---:|
| 92K session, decode | **3.6 tok/s** (hit 68.8%, 12,304 MB read) | not re-measured |
| 256-token prose bench, decode | 42.6 tok/s (23K-config test) | **41.8 tok/s** |
| stall charged to the following request | **62.8 s** | none observed |
| `expert_slots` | 13,523 | **13,523** — unchanged |

Two honest limits on that table: the 92K session was **not** re-run after the rollback — what was
verified is that the pool is gone (`conversation_cache_mib = 0`), the slots are intact, and a clean
256-token bench returns 41.8 tok/s at 0.99 hit. And the two decode rows are different workloads, so the
columns are not meant to be subtracted.

The slot count deserves its own line: **parking never bought VRAM.** The pool lives in host RAM, and
RAM pressure was the scarce resource to begin with.

---

## 6. Four measurement rules that came out of this

1. **Separate `reused` from `read` before calling anything "jitter".** A reuse is 72 ms; a cold read is
   55 s at 38K. If you mix them you will "discover" a 1000× variance that does not exist.
2. **A benchmark is an evictor.** If you are measuring against a live service, expect the first
   production request after your run to be a cold read. Do not log it as production latency.

A third rule got added when §4 was written:

3. **A verdict about a cache is a verdict about a *workload*, and workloads change.** "Serial, so parks
   are wasted" was true on 10-18 and false on 10-20 with the same binary and the same config. Record
   the traffic shape next to the verdict, or the verdict silently expires.

A fourth when §5 was written:

4. **Measure the cost at the size you will actually run.** The 23K A/B was executed correctly and still
   produced the wrong decision, because 23K parked in 6.7 s and production parked in 72 s. Write cost
   stops being linear in snapshot size the moment the kernel starts reclaiming to make room — and the
   session length that makes the *benefit* largest (Limit 1: the restore ceiling is fixed, so a longer
   session recovers a larger fraction) is the same one that makes the *cost* fatal. A benchmark that
   only exercises the cheap case cannot fail, and a result that cannot fail is not a result.
