# Raw per-request samples

These are the ground truth for every number in `../docs/`. If a table in the docs disagrees
with these files, the files are right and the doc is a bug.

All data was produced by the same harness: N arms in a palindromic order, each arm on a fresh
process start, 5 discarded preconditioning requests per workload, then 8 measured samples.
`temperature: 0` throughout.

| file | experiment | arms |
|---|---|---|
| `r17-lookup-chain-8arms.csv` | `--lookup-chain 3` vs default | 8 (A B B A A B B A) |
| `r18-suffix-draft-mtp-q4-8arms.csv` | `--suffix-draft 0` × `--mtp-q4 all`, 2×2 factorial | 8 |

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
