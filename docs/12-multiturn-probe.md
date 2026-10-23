# The benchmark was measuring the wrong thing: decode 38 vs 44–48

> **Short version.** Six unrelated prompts in rotation measure a *cold prefix*, and produce
> `decode ≈ 38 tok/s`. The same model, same engine, same configuration, answering a real
> conversation measures **44–48 tok/s**, with 47.6 at 8K and 49.1 at best. Nothing was tuned
> between those two numbers. The harness was wrong, not the engine.

This is the single most expensive mistake in this repository's history. Every conclusion built on
"decode is 38, the bigger model cost us 14%" had to be withdrawn, including the recommendation not
to upgrade the model at all.

---

## 1. What the old harness actually measured

`_abx.py` sends six prompts in rotation — `count`, `echo`, `prose`, and three variants — one after
another, every arm on a fresh process. That protocol is *correct* for comparing flags, because it
holds the workload constant and the noise stays symmetric across arms. It is *wrong* as a
description of production, and the two got confused.

| | six-case rotation | real conversation |
|---|---|---|
| prompt prefix | different for every case | same prefix, appended each turn |
| prompt reuse | **0%** | **99%** |
| expert-cache hit | **0.88** | **0.96** |
| prefill work per turn | full prompt every time | only the new few dozen tokens |
| resulting decode | **38** | **44–48** |

Eight points of hit rate is the whole mechanism. A cold prefix forces the expert pool to re-fetch
most of the hot set; a warm one is already resident. On top of that, the full prefill of every
round washes the cache slots that the previous round had just warmed.

So the gap is not measurement error in the statistical sense — it is a **13% systematic bias**, and
it pointed the wrong way: it made a good configuration look mediocre.

## 2. The probe that replaced it

`scripts/multiturn_probe.py` builds one `system` message plus an alternating
`user`/`assistant` history and appends one new `user` turn per round, reading `reused`,
`expert cache hit` and `decode` out of `/metrics` after each request. Two knobs matter:

- `--sys-k` — how big the session is (a 8K one, a 55K one);
- `--turns` — how many follow-ups, minimum 3 before the first sample counts.

Measured on a 160K-context production configuration, expert cache pinned at 11,240 slots:

| scenario | first turn | turns 2+ | prompt reuse | hit | decode |
|---|---|---|---|---|---|
| 8K session, 6 turns | 20.4 s | 4.9–6.0 s | 98.7% | 0.964 | 36.2 → **47.6** (max 49.1) |
| 55K session, 5 turns | 81.2 s | 3.8–4.5 s | 99.9% | 0.968 | 43.0 → **44.8** |

Raw per-turn samples: [`results/r30-multiturn-probe.csv`](../results/r30-multiturn-probe.csv).

Two side findings that turned out to matter more than the decode number:

1. **A 50K session costs 4 seconds per follow-up.** Long context is nearly free *inside* a session.
   The first turn pays 81 s, every turn after it is a rounding error.
2. **`reused` finally has a value.** It sat at 0 in `totals` for days, because no earlier harness
   ever sent a second turn on the same prefix. The metric was fine; the workload was missing.

## 3. The one real pain point: switching sessions

Inside a 46,185-token session, send one unrelated 3,065-token request, then come back:

| step | prompt | reused | wall |
|---|---|---|---|
| A1 first | 46,185 | 0 | 71.0 s |
| A2 follow-up | 46,197 | 46,180 | **2.8 s** |
| B interrupter | 3,065 | 0 | 10.6 s |
| A3 resume | 46,211 | **0** | **69.8 s** |

3K tokens of interruption erase the entire checkpoint for a 46K session. This is an `erase` in the
engine (`generate.cpp:11134-11137`), not a budget problem — `--prompt-cache 24` was already
configured and it still happens. It is not fixable by configuration.

With the 0.1.48 engine the same script gives `reused = 46,192` and **3.2 s** on the resume, because
the conversation cache parks the session's prompt instead of dropping it. Details in
[`13-engine-0.1.48.md`](13-engine-0.1.48.md).

### The behavioural rule that comes out of it

Do not keep two long sessions open at the same time **on engines before 0.1.48**. A single
interruption costs a full re-read of the other session. If you must, accept one 70-second stall per
switch; there is no flag that buys it back.

## 4. What this does to earlier conclusions

| earlier claim | status | why |
|---|---|---|
| "IQ3_S decodes at 38; the 44 of the smaller model is structurally out of reach" | **withdrawn** | steady state is 44–48, and 8K sessions reach 49 |
| "the bench number represents production" | **withdrawn** | it represents a worst-case cold prefix |
| "long context is the main pain" | **split** | a follow-up at 55K is 4 s; only *switching* hurts |
| "prefill is 655 tok/s at 32K, 715 at 130K" | stands | the 55K first turn measured 626 tok/s, consistent |
| "160K context is enough" | stands | verified on a 50K session end to end |
| "the model upgrade costs speed" | **reversed** | higher quality, equal-or-better speed, 160K context |

## 5. Protocol rule added to `02-methodology.md`

> **Benchmarks that rotate unrelated cases answer "which flag is better". They do not answer "how
> fast is it". Any statement about production speed must come from a same-prefix multi-turn probe
> with at least three follow-ups after the first.**

The corollary is unwelcome but true: for the rest of this repository, every *decode* number measured
with the rotation harness (r17, r18, r27, r28) is a lower bound, not an expectation. The *relative*
verdicts in those files are unaffected — both arms were equally cold.
