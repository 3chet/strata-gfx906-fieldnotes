# A 100K session, the 5-second verify timeout, and a number I misread

The failure looks like the server dying. It is the engine killing itself, deliberately, because a GPU
kernel did not come back within 5 seconds. This file is about how to tell that apart from the two
other ways this box dies, and about a log line that cost me a wrong diagnosis.

```
[engine] reading the prompt: 103,976 of 103,983 tokens, 18 s so far
[engine] reading the prompt:       1 of max 25600 tokens, 349525.3 tok/s, 19 s
[engine] reading the prompt:       1 of max 25600 tokens,       0.1 tok/s, 29 s
[engine] reading the prompt:       1 of max 25600 tokens,       0.0 tok/s, 39 s
[engine] the engine stopped unexpectedly (exit code -15).
         Unrecoverable native verification failure:
         verify: timed out at layer 32; its GPU waits were released
         but the GPU did not finish within 5 s (#267)
```

Exit code **−15** is SIGTERM, and in this signature it is *self-inflicted*: `verify` releases the GPU
waits, waits 5 s, and terminates the process rather than return a token it cannot vouch for.

---

## 1. `reading the prompt: 103,976 of 103,983` does not mean "it read 103,976 tokens"

This is the misreading, and it is a good one — the line looks exactly like an I/O progress counter.
It is not. **The number before `of` is the count already served from the prefix cache.** In this
request only **7** tokens were new.

The proof is in the same log, on requests that did not fail:

| prompt tokens | reused | actually read | prompt time |
|---:|---:|---:|---:|
| 99,935 | 81,920 | 18,015 | 64.4 s |
| 102,984 | 98,304 | 4,680 | 11.8 s |
| 101,862 | 100,408 | 1,454 | 26.3 s |
| **103,983** | **103,976** | **7** | **18 s** |

So the 18 s was **not** prefilling 104K. It was **restoring 103,976 KV cells into VRAM**. A full
104K prefill on this box costs ~194 s (measured, 535 tok/s — see §5); 18 s would be three times faster
than the hardware can read the prompt.

**How to check before you believe a prefill number:** read `reused` and `prompt_read` from
`/metrics`, never the log line. `prompt_read == prompt_tokens` means a real prefill; anything else is a
restore, and a restore's duration is an I/O number, not a compute number.

> This is the same family of error as [07 §G3](07-corrections.md#g3-metrics-spec-is-not-argv-spec):
> a value that looks like one thing is reporting another. The general rule holds — **the log is a
> progress display; `/metrics` is the measurement.**

---

## 2. It was not the OOM, and it was not the earlier SVM failure

Three things on this box end the same way (exit −15 / the same one-line error), and only the log text
separates them:

| signature | what died | where to look |
|---|---|---|
| `verify: timed out at layer N` | engine suicide, GPU wait > 5 s | engine log, `verify.cpp` |
| `no progress for 60 s` (exit **−6**, SIGABRT) | watchdog suicide, GPU stalled | stall report: `0 layers served`, `host idle > 100 s` |
| `running out of memory` | kernel OOM killer | `dmesg`, `oom-kill` |

Checks that actually ruled the other two out:

- **OOM: no.** `dmesg` had no `oom-kill`; swap was 1.8 GB of 32 GB; `MemAvailable` 41 GB.
- **SVM: no, and this one is a trap.** There *were* 12 `amdgpu: SVM mapping failed` lines that day —
  at **11:37**, belonging to a crash at **11:47**. This request failed at **22:20**. Same day, same
  box, unrelated failure. Always match the timestamp of the kernel message to the timestamp of the
  crash before wiring them together; a day's worth of `dmesg` is not evidence about one event.

---

## 3. The 5 seconds cannot be raised, lowered, or turned off

`verify` calls `release_gpu_waits(5000)` with the timeout **hard-coded**. There is no flag. Disabling
it is not an option either: the request would hang forever with no error, which is strictly worse than
a crash that restarts the engine in ~30 s.

So every "fix" for this failure has to be a fix for *why the GPU took more than 5 s*, not for the
check. That reframing is what makes the rest of this file short.

---

## 4. The KV cache is 0.47 GiB, not 3.87 GiB — and lowering `--max-context` buys nothing

I had this wrong by a factor of eight in an earlier note, so it is worth recording properly.

`--max-context 163840` **is fully allocated at startup** — the help text for `--kv-grow` says so
outright ("the whole --max-context allocated at start"), and `--kv-grow` is unavailable here anyway
because it requires `!multi_gpu` (`generate.cpp:4397`). So the reservation really is fixed and
independent of how long the conversation is.

But the reservation is small. Measured, from the one experiment that forces the engine to say it out
loud (`--kv-resident 40960`, which streams most of the KV from pinned RAM):

```
KV streaming: 40960 of 163840 cells per QSA layer in VRAM, the K/V in 0.35 GiB of pinned RAM
```

0.35 GiB for 40,960 of 163,840 cells ⇒ the whole thing is **≈0.47 GiB**, split across both cards.
My earlier estimate of 3.87 GiB came from `48 layers × 163840 cells × 528 B/cell` and was wrong by
8× — the per-cell figure is not the right multiplier across a layer split.

**Consequences, and they are all "do not bother":**

| idea | why it does not pay |
|---|---|
| lower `--max-context` to buy expert slots | 163840 → 98304 frees ~0.15 GiB. A few dozen slots. And it rejects the 100K sessions this box exists to serve |
| `--kv-resident N` to move KV out of VRAM | works, but see [04 §15](04-what-not-to-tune.md#15---kv-resident--rejected-measured-at-a-net-loss) — **+3.9% slots for −6.9% decode** |
| `--kv q4_0` → something smaller | already the smallest: q4_0 (528 B/cell) < k8v4 (816) < int8 (1056) < fp16 |
| `--kv-grow` | single-GPU only |

`kv_resident: 0` in `/metrics` is the correct, most-compact state, not a missed opportunity.

---

## 5. Why the GPU took more than 5 s: it went to disk

The mechanism is a cache flush, and the log states it:

```
CUDA0 prompt path borrows 5013 cache slots (7.00 GiB)
CUDA1 prompt path borrows 4011 of its 5931 slots (7.00 GiB)
```

14 GiB of expert-cache slots are borrowed to hold the prompt, which evicts the expert pages that were
sitting there. After the restore, the first decode token needs experts that are no longer resident,
and with a 42 GiB expert mmap on a 47 GB box they come from **disk**:

```
file tier I/O: OS read 11553.5 MB (25391 major faults)
```

11.5 GB of page-ins and 25,391 major faults. That is what overruns 5 s.

### It is not deterministic — I tried to reproduce it and could not

Same shape as the crash: build a ~104K prompt, then send it again with a handful of extra tokens so
the restore and the first decode token happen together.

| round | prompt | reused | read | restore | decode | hit | outcome |
|---|---:|---:|---:|---:|---:|---:|---|
| A, cold | 104,548 | 0 | 104,548 | **194.4 s** (535 tok/s) | 29.4 | 0.914 | survived |
| B, resume | 104,551 | **98,304** | 6,247 | **18.7 s** | 33.7 | 0.955 | **survived** |

Round B's 18.7 s is within noise of the 18 s that preceded the crash — **and it did not crash.** So
"104K kills it" is false. What the failing session had, and this reproduction did not, was **five
consecutive resumes at 97K → 104K**, each one flushing the expert cache again before it had warmed
back up. The 5 s wall is crossed on the fifth attempt, not the first.

**Practical reading:** this is a cumulative-pressure failure with a stochastic edge. Long context
makes it likely; consecutive long restores make it near-certain; a single long request usually
survives.

### The second trigger, same wall, different cause

The same signature appeared later the same day on a request whose context was small:

```
writing a tool call: write: 1919 of max 25600 tokens, 48.0 tok/s, 80 s
writing a tool call: write: 1919 of max 25600 tokens, 30.6 tok/s, 103 s
verify: timed out at layer 34
```

The token count stopped moving — generated 1,919 of a requested 25,600 and then stalled. This is the
**long continuous single-output** path: a multi-thousand-token tool argument holds the decode loop
long enough for one slow expert fetch to miss the 5 s window. Two different triggers, one check.

---

## 6. What actually reduces the exposure

Ordered by cost, cheapest first:

1. **Keep a single session under ~70K.** Everything above that is walking the line. When a session
   passes ~60K, compress or start fresh **before** it grows, not after it fails.
2. **Turn on the conversation cache** ([10 §4](10-prefix-cache.md#4-turning-it-on-what-a-multiplexed-workload-measures)).
   It does not touch the 5 s check, but it cuts the restore work that precedes the flush — 53 → 14 s
   on a 23K session, and proportionally more on a 100K one.
3. **More RAM.** This is the one hardware fix that is specific to this failure rather than generic
   "stability": every expert page that stays resident is a page that is not a major fault. 42 GiB of
   experts in 47 GB of RAM is the whole problem, and 64 GB removes it.
4. **Do not build an A/B that restarts the engine mid-session.** A restart is a cold read; if your
   harness measures across one you will attribute the restore to the setting under test.

What does **not** help: raising `--max-context` priority anywhere, lowering it, tuning KV, or adding
`--kv-resident`. The failure is an expert-cache miss, not a KV problem — the two are easiest to
confuse exactly because both are "memory" and only one is the bottleneck.
