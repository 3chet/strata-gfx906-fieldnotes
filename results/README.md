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

**r17/r18 are decode experiments on 0.1.44.1 with `--batch 2`. r19–r22 are 0.1.45 with `parallel: 1`.**
They do not share a baseline; do not merge them into one table.

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
