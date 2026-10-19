# Concurrency, pipeline windows, and what 64 GB of RAM would actually buy

Three questions, one file, because the answers interlock:

1. Does `--pipeline-windows 2` help? **No — and it was never running.**
2. Does `parallel: 2` pay? **Only if two requests overlap. Then +12.6%; otherwise −8.3%.**
3. Would 64 GB let me run two lanes? **You can run two lanes now. 64 GB buys stability, not concurrency.**

---

## 1. `--pipeline-windows 2` — rejected, and the flag had never been on

`--pipeline-windows N` is **not** a concurrency setting. It is how many pipeline *stages* overlap:

| value | meaning |
|---:|---|
| 0 | off (same as `STRATA_PIPELINE_AUTO=0`) |
| 1 | overlap prompt short-reads only |
| 2 | also overlap decode: stage 0 starts the next window while stage 1 verifies the current one |

The second card stops waiting for the first. It guesses "whole window accepted + bonus token hit" and
rolls back a recurrent-state copy when wrong.

### It was being silently disabled

`generate.cpp:3532-3541`:

```cpp
if (o.batch != 0) {
    // pipeline is not with --batch slots
    o.pipeline_windows = 0;      // on the auto path: no log line at all
}
```

And `--batch` was not in `argv` — it was appended by the server from the top-level config
(`serve/server.py`, `parallel_args()`): `"parallel": 2` → `--batch 2`.

So the sequence was: set `--pipeline-windows 2` → engine accepts the flag → server appends `--batch 2` →
engine sets it back to 0 → **no error, no warning, no log line.** Every earlier "no effect" reading of
this flag on this box was measuring the default.

### Measured (three arms, restart each, 8.3K prefill prompts, 256-token greedy decode)

| arm | config | decode | prefill 8.3K | prefill spread | slots | verdict |
|---|---|---:|---:|---:|---:|---|
| A | `parallel: 1`, no pipeline | 42.0–44.3 | **491.7** | 1.4% | **13,767** | — |
| B | pipeline 2, draft on last card | 42.8 | **361.0** | **190%** | 13,439 | ❌ |
| C | pipeline 2 + draft on first card + subset vocab | 40.8 | 443.1 | 3.5% | 12,983 | ❌ |

- **B: prefill −26.6%** versus A, with the spread blown out 1.4% → 190%. The engine had warned that the
  draft layer was on the wrong card and fighting the last stage for the same stream — `mtp_first_default_on()`
  is false on gfx906 because `decode_defaults_arch_ok()` only accepts gfx1200/1201.
- **C: fixed the warning, still lost.** Moving the drafter to card 0 (`STRATA_MTP_STAGE0=1` plus
  `--mtp-draft-vocab`) did recover prefill to 443 and the spread to 3.5%, but the subset vocabulary
  (106,299 tokens) dropped draft acceptance to 63.8–73.9% against A's 74–76%, and decode fell to **40.8
  — below A**.

The upstream +21% is gfx12 data. **On gfx906, do not retry this.**

### The one real gain in that round was not the pipeline

Removing `--batch 2` to make the test possible was worth **+13–16% slots** (11,897 → 13,529–13,767) and
+2.4–2.8 GiB of expert cache, at zero VRAM cost. That turned into [07 §C1](07-corrections.md#c1-delete-batch-2-do-not-keep-it):
the setting worth deleting was the one I had been recommending to keep.

---

## 2. `parallel: 2` — a real +12.6%, if you actually overlap

Same model, same box, restart per setting, steady-state medians, 256-token greedy:

| | single request | two at once | three at once | slots | feel |
|---|---:|---:|---:|---:|---|
| **`parallel: 1`** | **44.3–44.7** | 43.0 | — | 13,529–13,767 | second request waits **6.0 s** |
| `parallel: 2` | 40.9 (**−8.3%**) | **48.4 (+12.6%)** | 46.2 | 11,901 (**−12%**) | both lanes run, ~25 tok/s each |

`parallel: 2` does not double anything. It packs two sequences into one batch window
(`batch windows of up to 2 sequences (layers [0,15))`) so the GPU idles less. Each extra slot is a full
session — `2 slot sessions on CUDA1 (1.09 GiB each)` plus `0.82 GiB of CUDA0` — taken directly out of
the expert cache. Hence −12% slots and −8.3% on a single request.

Three is worse than two: there are only two batch slots, so the third queues while still holding KV and
scheduling overhead. **Two is the sweet spot on this box.**

### Prefill does not parallelise at all

Two 8.7K prompts sent simultaneously:

| | first | second | total |
|---|---:|---:|---:|
| one prompt | 19.6 s | — | 19.6 s |
| two at once | 19.1 s | 19.4 s | **39.5 s** |

39.5 ≈ 19.1 + 19.4. Strictly serial. Batch applies to decode only; the prompt phase still takes the
whole GPU. **Two long sessions arriving together means the second one waits for the first's prefill**,
whatever `parallel` says.

### Decision rule

```
overlap ≥ a few % of requests  → parallel: 2   (+12.6% aggregate)
one session at a time          → parallel: 1   (the default here; +8.3% single-request, +14% slots)
```

Measure overlap before choosing; the method is in [06 §3](06-reproduce.md#3-check-whether-concurrency-exists-before-tuning-for-it).
On this box production overlapped in 1.4% and 0.1% of requests, which is why `parallel: 1` is the
production setting even though `2` wins on aggregate throughput.

---

## 3. 64 GB: what it buys, and what it does not

The question was "does 64 GB let me run two lanes?" The answer is no, because two lanes do not need it.

### The memory ledger, measured

| | |
|---|---:|
| physical | 47,068 MB (4 DIMMs, mixed 8+16+8+16 @ 1866 MT/s) |
| engine `VmRSS` | 43.4 GiB |
| — `RssFile` (mmap'd expert pack) | **40.0 GiB** of 42 GiB on disk |
| — `RssAnon` + `Shmem` | 3.7 GiB |
| `free` | **348–844 MB** |
| swap in use | **1.8 GB** |
| `available` | 41 GB ← **this number is a lie** |

`available` counts the mmap'd clean file pages as reclaimable. They are — but reclaiming them means the
next expert miss reads from disk. And SVM pinning needs pages that *cannot* be reclaimed, which is
exactly the failure recorded in this box's crash log:

```
amdgpu: SVM mapping failed, exceeds resident system memory limit
```

12 of those preceded an `exit code -6` (SIGABRT from the 60 s watchdog: the kernel was waiting on data
that was not resident, no progress was reported, and the engine killed itself).

### But the cache hit rate is already 99.87%

```
file tier I/O this request: the OS read 9.8 MB from storage (72 major faults)
                            for 7690.8 MB of expert reads
```

That is the number that settles the question. **The experts are already in RAM.** There is no second
lane's worth of throughput hiding in more memory.

| 64 GB gives you | 64 GB does not give you |
|---|---|
| no SVM crash: ~20 GB headroom makes the pin always succeed | more concurrency (hit rate is already 99.87%) |
| no swap (currently 1.8 GB) | a bigger expert cache (`expert_slots` is bounded by VRAM) |
| 100% expert residency (40 of 42 GiB today) | faster prefill or decode |
| headroom for builds, backups, docker | — |

**Cheapest path:** the board (R5 2600) caps at **64 GB**. Four slots are already occupied, so
"2×16 GB replacing the two 8 GB sticks" gets there without a CPU change; 128 GB would require one.

### When to turn the conversation cache back on

`--conversation-cache-mib` is the one setting that becomes cheap after the upgrade — see
[10 §3](10-prefix-cache.md#3-the-fix-and-why-it-is-off-today). At 64 GB the 1.1–1.5 GB it holds is no
longer squeezing the page cache, and the 33.7 s first park will not trigger a reclaim stall behind it.

> **Pending:** the 64 GB measurement is not done. This section is a prediction from the ledger above,
> not a result. When the RAM arrives, re-run [10 §3](10-prefix-cache.md#3-the-fix-and-why-it-is-off-today)
> and the crash count before trusting it.
