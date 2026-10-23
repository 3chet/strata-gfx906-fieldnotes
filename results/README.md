# Raw per-request samples

These are the ground truth for every number in `../docs/`. If a table in the docs disagrees
with these files, the files are right and the doc is a bug.

All data was produced by the same harness: N arms in a palindromic order, each arm on a fresh
process start, 5 discarded preconditioning requests per workload, then 8 measured samples.
`temperature: 0` throughout.

| file | experiment | arms / rows |
|---|---|---|
| `r17-lookup-chain-8arms.csv` | `--lookup-chain 3` vs default | 8 arms (A B B A A B B A), 312 rows |
| `r18-suffix-draft-mtp-q4-8arms.csv` | `--suffix-draft 0` × `--mtp-q4 all`, 2×2 factorial | 8 arms, 312 rows |
| `r19-prefill-chunk-4arms.csv` | prefill chunk 16384 / 8192 / 20992 on a fixed 32,209-token prompt | 4 arms × 7, 28 rows |
| `r20-prefix-reuse.csv` | reuse vs eviction on a 38,469-token conversation | 9 steps |
| `r21-checkpoint-eviction.csv` | evictor size 1,986 / 15,366 / 38,305 / 68,895 tokens | 9 steps |
| `r22-conversation-cache.csv` | `--conversation-cache-mib` 768 (fails) vs 1280 (works) | 2 budgets, 12 steps |
| `r23-conversation-cache-multiplexed.csv` | the same flag on a **multiplexed** workload: 4 arms, one 23,407-token session, a ~70-token interrupter between resumes | 4 arms × 3 steps, 12 rows |
| `r24-kv-resident.csv` | `--kv-resident 40960` vs off: slot gain against decode cost | 2 rows |
| `r25-long-context-restore.csv` | the 103,983-token request that died, and a 104K reproduction that did not | 3 rows |
| `r26-conversation-cache-rollback.csv` | why r23's flag was removed an hour later: park rate falls 84 → 22 MB/s once the snapshot passes ~600 MB | 5 rows |
| `r27-stage-tuning-arms.csv` | the 2026-10-23 tuning campaign on 0.1.46: context 204800→163840, prefill 8192→16384, ring 768→384, plus five rejections | 10 arms |
| `r28-fixed-cache-io-prefetch.csv` | `STRATA_IO_PREFETCH` 0 vs 1, re-run with `--expert-cache 11240` pinned: identical decode, 33 fewer slots | 2 arms |
| `r29-long-prefill.csv` | 66,301- and 123,047-token prompts: prefill throughput **rises** with length | 4 rows |
| `r30-multiturn-probe.csv` | the same-prefix multi-turn probe that invalidated every earlier decode figure: 8K and 55K sessions | 11 rows |
| `r31-interleaved-session.csv` | a 46K session interrupted by an unrelated 3K request, on 0.1.46 and on 0.1.48 | 8 rows |
| `r32-v148-abba.csv` | 0.1.46 vs 0.1.48, and `STRATA_SPEC_COST` 0 vs 1, palindromic arm order, 3 rounds each | 6 rows |
| `r33-v148-prefill-68k.csv` | the 68K prefill cost of 0.1.48's "prompt path borrows expert slots" mechanism | 4 rows |

**r17/r18 are decode experiments on 0.1.44.1 with `--batch 2`. r19–r22 are 0.1.45 with `parallel: 1`.**
They do not share a baseline; do not merge them into one table.

**r27–r33 (2026-10-23) are 0.1.46 and 0.1.48 with `parallel: 1` and `--expert-cache 11240` pinned.**
Two different harnesses appear here and they do not agree on purpose: r27/r28 use the six-case
rotation (cold prefix), r30–r32 use the same-prefix multi-turn probe (warm). The cold numbers read
~13% lower by construction — see [`../docs/12-multiturn-probe.md`](../docs/12-multiturn-probe.md).
Compare r27/r28 only against each other, and r30–r32 only against r30–r32.

## Columns

| column | meaning |
|---|---|
| `arm` | arm label; arms sharing a `spec`/`value` are the same configuration on two different restarts |
| `value` / `spec` | the setting under test. `''` = the production default. In r18, a combined arm is written `a+b` |
| `workload` | `count` (1..60, 128 tok out), `echo` (repeat a passage, 192), `prose` (original text, 192) |
| `phase` | `pre` = preconditioning (**discarded**), `meas` = measured |
| `sample` | 1..N within that phase |
| `reused` | prompt tokens served from the prefix cache |
| `generated` | output tokens produced |
| `decode_ms` | decode duration as the engine reported it |
| `tps` | decode tokens/s as the engine reported it |
| `accepted` / `total` | draft tokens accepted / proposed |
| `hit_pct` | **expert-cache hit rate for that request** — the plateau indicator |
| `t_arm_start` | unix timestamp of the arm's first request; used for the drift term |
| `txt_sha` / `txt_len` | r18 only: sha256 prefix and length of the reply |

### Columns in r19–r22

| column | meaning |
|---|---|
| `prefill_arg` | what was passed to `--prefill` |
| `resolved_chunk` | **what the engine actually used** (printed in the startup banner) — this is the column to trust |
| `process_age` | how long the engine process had been up; it changes the spread, not the median |
| `read_ms` / `prefill_tps` | the fresh-read half of the request, from `/metrics` (`prompt_read / prompt_ms`) |
| `hit_pct` | expert-cache hit rate for that request (0–1 in r19) |
| `reused` / `read` | prompt tokens served from the prefix cache vs actually read. `read == prompt_tokens` means it was a real prefill sample |
| `cc_parks` / `cc_restores` | conversation-cache parks and restores after that step |
| `cc_bytes` | host RAM held by parked snapshots, in bytes |

### Columns in r23–r26 (reduced sets — read this before using them)

These files record only what the instrument actually reported; they are not re-derivable from a
full harness run, and they deliberately contain **no column I did not measure**.

| column | meaning |
|---|---|
| `cc_mib` / `cc_park_gain` / `cc_min_tokens` | the three conversation-cache flags for that arm. `0/0/0` = the flag is off |
| `snapshot_mib` / `park_ms` / `park_mbs` | the parked snapshot's size, how long the write took, and the implied rate. In r26 a blank `park_ms` means **no park line was emitted** — the engine died first |
| `interrupter_tokens` | size of the throwaway request inserted between resumes, to destroy the checkpoint |
| `reused` | prompt tokens served from the prefix cache. **The column that decides everything** — `0` next to a non-zero `session_tokens` means the checkpoint was destroyed |
| `restart` | which fresh-process arm the row belongs to. r24's two arms are on separate restarts |
| `kv_pinned_gib` | K/V moved to pinned host RAM, as the engine printed it at startup |
| `block_reads_vram_pct` | share of KV block reads served from VRAM rather than host RAM (r24) |
| `decode_median_tps` | decode median; `n_decode` says how many samples it is the median of |
| `prompt_ms` / `read` | the restore-or-prefill half. `read == prompt_tokens` ⇒ real prefill; anything else ⇒ restore |
| `outcome` / `source` | `source = engine-log` rows are quoted from the log and are approximate; `source = metrics` rows come from `/metrics` |

Two cautions specific to these files:

- **r24's `off` arm reads 13,767 total slots, and production later read 13,522.** Same config, different
  restart: `K` and the learned expert profile move the allocation between boots (see
  `../docs/07 §G1`). Compare an arm only against an arm from the same restart.
- **r25 row `r1` is not a measurement of a completed request.** It is the failing request, quoted from
  the log; `prompt_ms 18000` is "18 s so far" at the last progress line, and `decode_tps 0.0` is what
  the engine printed while stalled. It exists so the two failure modes can be compared against the
  successes, not as a throughput sample.
- **r26 row `on-92k` has no `park_ms`, and its `snapshot_mib` is derived, not measured.** The engine was
  killed during that park and never printed a size; 2,239 MiB comes from the 24.75 KB/token unit cost
  measured on the two rows above it. Its `decode_tok_s` / `hit_rate` / `disk_read_mb` are real
  `/metrics` values.
- **The two big rows in r26 are not a one-variable A/B.** They differ in prompt length (92,628 vs
  78,157) *and* in whether a 2.24 GiB snapshot was resident. The file records the magnitude of the
  production failure; the causal claim about the pool rests on the park timings in the same file and on
  both engines dying in stage `parking`, not on that pair alone.
- **A park is charged to the *next* request.** In `on-78k` the 78K request itself was served normally
  (113.7 s, 36.3 tok/s); the 61.4 s write then blocked the following 62-token request for 62.8 s.
  Reading that row as "78K runs at 36 tok/s" is right; reading it as "the park is free" is not.

## Two things to know before analysing these

**1. `phase == 'pre'` rows are not measurements.** They are the cold-start ramp, kept on purpose
so you can see it (and so the pre-conditioning can be checked). Every statistic in the docs uses
`phase == 'meas'` only.

**2. The hit rate tells you whether a sample is on the plateau.** A `meas` row with `hit_pct` far
below the arm's median was taken before the cache settled. Sample 12 of arm A0 in the r17 file
(43.2 tok/s at 96.1%) is exactly that — which is why the docs use medians and report MAD.

## Reproducing the aggregates

```python
import csv, statistics as st
rows = [r for r in csv.DictReader(open('r17-lookup-chain-8arms.csv'))
        if r['phase'] == 'meas']
for wl in ('count', 'echo', 'prose'):
    for arm in ('A0', 'A0b', 'B1', 'B1b'):
        v = [float(r['tps']) for r in rows if r['workload'] == wl and r['arm'] == arm]
        print(wl, arm, round(st.median(v), 2), round(st.median([abs(x - st.median(v)) for x in v]), 2))
```

That reproduces the arm medians in `docs/03-readings.md` §3. From those medians, the
drift-corrected fit in `docs/02-methodology.md` §3.3 gives the effect and its resolution.

## Rows: 312 per file

8 arms × 3 workloads × 13 requests (5 pre + 8 meas) = 312. Every arm has the full 39.
