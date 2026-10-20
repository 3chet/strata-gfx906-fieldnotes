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

> **This section is history. Read [§4](#4-turning-it-on-what-a-multiplexed-workload-measures) before
> copying anything from it.** The "off" verdict below was correct for a client that runs one
> conversation at a time. It did not survive a client that keeps three or four alive — on that
> workload the flag is **on in production, and it cut recovery time by 73%**.

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
sub-agent with its own context, or an A/B harness running beside production. Then the 55 s → 0.5 s
restore is worth 1.1 GB. **This is the case production turned out to be in** (§4), not the serial case
§3 was written for.

After a 64 GB upgrade, turn it on by default (`-mib 1536`): the reclaim storm behind those 29/109 s
samples is a memory-pressure artefact, and the pressure is what the upgrade removes. **This is a
prediction, not a measurement — see [09 §3](09-concurrency.md#3-64-gb-what-it-buys-and-what-it-does-not).**

### One warning about the guard rail

`--conversation-cache-min-free-mib` defaults to **2560** and is meant to stop parking when memory is
tight. On this box `MemAvailable` reports **41 GB** while `free` is 350 MB — because mmap'd clean pages
count as available. **So the guard never fires.** Only the `-mib` budget actually bounds it. Do not rely
on the min-free check to protect you.

---

## 4. Turning it on: what a multiplexed workload measures

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

### The configuration in production

```
--conversation-cache-mib 4096          # ~2 snapshots of a 100K session at ~20.4 KB/token
--conversation-cache-min-tokens 20000  # short requests must not occupy a slot
--conversation-cache-park-gain 2000    # only re-snapshot after 2K of growth
```

`min-tokens 20000` is the setting that makes this safe: without it, every 70-token request parks,
walks the pool, and pays the 12–18 s starvation cost. It also means sessions below 20K get **no
benefit** — which, given Limit 1, they were not going to get much of anyway.

### What would make me turn it off again

- A genuinely serial client. Run the `uniq -c` one-liner in §3 before believing this.
- A box where `free` is under ~2 GB. The reclaim storm described in §3 is a memory-pressure artefact;
  4 GB of pool on a 47 GB box with 41 GB available is not.
- Any workload dominated by sessions under 20K. The restore ceiling makes them poor customers for a
  slot.

---

## 5. Two measurement rules that came out of this

1. **Separate `reused` from `read` before calling anything "jitter".** A reuse is 72 ms; a cold read is
   55 s at 38K. If you mix them you will "discover" a 1000× variance that does not exist.
2. **A benchmark is an evictor.** If you are measuring against a live service, expect the first
   production request after your run to be a cold read. Do not log it as production latency.

A third rule got added when §4 was written:

3. **A verdict about a cache is a verdict about a *workload*, and workloads change.** "Serial, so parks
   are wasted" was true on 10-18 and false on 10-20 with the same binary and the same config. Record
   the traffic shape next to the verdict, or the verdict silently expires.
