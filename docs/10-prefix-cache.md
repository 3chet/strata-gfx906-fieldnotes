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

## 3. The fix, and why it is off today

`--conversation-cache-mib` (default **0 = off**) parks a session's checkpoint in host RAM instead of
destroying it, and restores it when that conversation comes back.

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

### Why production does not use it

Eighteen consecutive production requests had **monotonically increasing** `in_tokens`
(29,644 → … → 38,882). That is a serial single conversation appending to the same prefix every turn.

- Benefit of parking: **zero** — nothing else ever competes for the checkpoint.
- Cost per turn: **0.5–1.0 s** plus 1.1 GB.
- Net: negative.

Removed. `conversation_cache.enabled = false`, zero `conversation-cache` flags in `argv`.

### When to turn it on

```bash
--conversation-cache-mib 1024
--conversation-cache-slots 2
--conversation-cache-min-tokens 4096
--conversation-cache-park-gain 8192      # do not snapshot every turn
```

Turn it on when **two conversations with different prefixes** alternate — two client sessions, a
sub-agent with its own context, or an A/B harness running beside production. Then the 55 s → 0.5 s
restore is worth 1.1 GB.

After a 64 GB upgrade, turn it on by default (`-mib 1536`): the reclaim storm behind those 29/109 s
samples is a memory-pressure artefact, and the pressure is what the upgrade removes. **This is a
prediction, not a measurement — see [09 §3](09-concurrency.md#3-64-gb-what-it-buys-and-what-it-does-not).**

### One warning about the guard rail

`--conversation-cache-min-free-mib` defaults to **2560** and is meant to stop parking when memory is
tight. On this box `MemAvailable` reports **41 GB** while `free` is 350 MB — because mmap'd clean pages
count as available. **So the guard never fires.** Only the `-mib` budget actually bounds it. Do not rely
on the min-free check to protect you.

---

## 4. Two measurement rules that came out of this

1. **Separate `reused` from `read` before calling anything "jitter".** A reuse is 72 ms; a cold read is
   55 s at 38K. If you mix them you will "discover" a 1000× variance that does not exist.
2. **A benchmark is an evictor.** If you are measuring against a live service, expect the first
   production request after your run to be a cold read. Do not log it as production latency.
