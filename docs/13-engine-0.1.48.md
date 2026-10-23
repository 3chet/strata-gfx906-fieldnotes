# Upgrading the engine: 0.1.46 → 0.1.48.1, and why it is worth it for a reason nobody advertises

> **Short version.** Decode is unchanged, prefill drops 2% for a mechanical reason, and the one thing
> that changes how you *use* the machine — resuming an interrupted long session — goes from **70 s to
> 3 s**. The upgrade is not faster. It is usable in a way it was not before.

Upstream: `v0.2.1` → `v0.2.3.1`, 428 commits, 86 files across `src/` `include/` `serve/`
(+7,827 / −265). Engine self-reports `0.1.48.1`.

---

## 1. Building it on gfx906

The build is the same recipe as always (`-DSTRATA_HIP_GFX906=ON -DCMAKE_HIP_ARCHITECTURES=gfx906`),
plus three things that cost real time:

### 1.1 The patch still applies — barely

`git apply --3way` against the accumulated local patch conflicted in **two** files, the same two as
the previous upgrade: `CMakeLists.txt` and `serve/server.py`. Both were resolved by taking upstream,
because upstream had already absorbed the rocBLAS / w4a4 / `moe_f16_kq` fixes the patch carried.

> The lesson is stable across two upgrades now: the CMakeLists conflict *looks* apocalyptic
> (25 upstream revisions) and never is.

### 1.2 The build container has no outbound network

CMake's `FetchContent` pulls llama.cpp from GitHub. Inside the build container that times out after
135 s, three times, then fails. Fetch the pinned commit on the **host** (a proxy is fine, this is a
public repo) into a directory and point CMake at it:

```bash
git -C third_party/llamacpp-pinned fetch --depth 1 origin <pinned-sha>
cmake -DSTRATA_GGML_DIR=/src/third_party/llamacpp-pinned ...
```

The SHA must match `third_party/ggml/VERSION.txt`, otherwise you get a silently different ggml than
the one upstream tested.

### 1.3 Upstream ships a HIP build that does not compile

**This is the only source change needed, and it is upstream's bug:**

```c
/* include/strata/platform/hip_compat/strata_hip.h */
#define cudaStreamCreateWithPriority hipStreamCreateWithPriority
#define cudaDeviceGetStreamPriorityRange hipDeviceGetStreamPriorityRange
```

Missing symbols are used at `src/core/dflash2.cpp:205-206`. Without the two defines the gfx906
build fails outright, while the CMake comment claims DFlash2 "exists in both CUDA and HIP builds".
Upstream CI does not run the opt-in gfx906 build, so nobody noticed.

### 1.4 Your existing pack is fine

`tools/iq_pack.py` between 0.2.1 and 0.2.3.1 only gained **resumable packing** (a killed pack can be
continued). The pack format did not change — an IQ3_S pack built by the older tool loads unmodified.

## 2. What the comparison actually says

Method: same pack, same 36 CLI arguments, `--expert-cache 11240` pinned, `--max-context 163840`,
palindromic arm order (0.1.48 → SC → SC → 0.1.48) to cancel the 3–4% evening thermal drift, three
rounds per arm, judged on the median. Every arm was measured with the multi-turn probe from
[`12-multiturn-probe.md`](12-multiturn-probe.md), never with case rotation.

### 2.1 Decode: three arms, one noise band

| arm | 8K (3 runs) | mean | 55K (3 runs) | mean |
|---|---|---|---|---|
| 0.1.46 production | 45.1 | — | 44.8 | — |
| 0.1.48, `STRATA_SPEC_COST=0` | 44.7 / 43.5 / 46.5 | 44.9 | 45.7 / 42.6 / 44.5 | 44.3 |
| 0.1.48, `STRATA_SPEC_COST=1` | 46.6 / 46.2 / 45.1 | 46.0 | 48.4 / 44.7 / 41.7 | 44.9 |

Everything sits in 44–46 tok/s. Repeat measurement of one fixed configuration spans ±4–8%, so a
"2% win" here is not a win — it is the same number drawn twice.

Raw: [`results/r32-v148-abba.csv`](../results/r32-v148-abba.csv).

**`STRATA_SPEC_COST` is not detected.** It is the only new switch in 0.1.48 that touches decode
directly (cost-aware MTP window, bucketised by context length). Mean +2.4% at 8K, +1.5% at 55K —
both inside the floor, and both times the first two runs looked good and the third collapsed. That
is the signature of noise. Not adopted.

### 2.2 Prefill: 2% lower, and the log says why

| measurement | 0.1.46 | 0.1.48 | delta |
|---|---|---|---|
| 68K cold prefill, two runs | 675 / 683 tok/s | 669 / 659 tok/s | −0.9% to −3.5% |
| 55K first-turn wall clock | 81.2 s | 81.8 s | flat |

This is not a regression, it is a new mechanism:

```
strata serve: the prompt path borrows 4137 CUDA0 cache slots (7.13 GiB)
strata serve: CUDA1 prompt path borrows 3607 of its 4969 slots (7.13 GiB)
```

0.1.48 lends expert slots to the activation buffer *during* prefill so that longer prompts fit.
Fewer expert slots stay resident while a long prompt is being read, so the hit rate dips slightly.
The 0.1.46 log has no `borrows` line at all — the mechanism did not exist.

A warning also appears that did not before:

```
--expert-cache 11240 leaves no room for the prompt path's buffers (0 MiB)
and the 1024 MiB reserve on CUDA0
```

The same value was silent on 0.1.46. The new engine's VRAM accounting is tighter; if you pin the
slot count, re-check `--vram-reserve-mib` or accept the auto slot count.

### 2.3 The actual payoff: the conversation cache is on

| scenario | 0.1.46 | 0.1.48 |
|---|---|---|
| resume a 46K session after a 3K interruption | reused 0, **69.8 s** | reused 46,192, **3.2 s** |
| switch between two long sessions | full re-read each way | 3.7 s / 3.3 s / 3.1 s, all hitting |
| park rate | (not engaged) | ≈5 GB/s — 51K tokens in 0.5–0.6 s |
| capacity | (not engaged) | 8192 MiB, 4 conversations, `evictions=0` |

The engine sizes it from free RAM instead of a hand-set `--conversation-cache-mib`:

```
strata serve: conversation cache sized from the free RAM: 8192 MiB for up to 4 parked
conversations, so an agent's next turn reuses its prompt
strata serve: conversation cache: parked 50978 tokens in 618.7 ms;
parked=3 bytes=2550090200 evictions=0
```

Raw: [`results/r31-interleaved-session.csv`](../results/r31-interleaved-session.csv).

### 2.4 Why the "22 MB/s" verdict does not survive the version change

[`10-prefix-cache.md`](10-prefix-cache.md) concluded the conversation cache could never be used
because parking ran at **22 MB/s**, so a 90K snapshot would take 100 s and trip the 60 s watchdog.

That 22 MB/s is a real log line from 0.1.45 — it is not a bad derivation. But it measures a
*different implementation under different memory pressure*:

```
# 0.1.45, budget hand-set, park competes with the expert pages
parked 78157 tokens in 61431.8 ms; bytes=1418474608    #  1.35 GiB @ 22 MB/s

# 0.1.48, cache sized from free RAM at startup
conversation cache sized from the free RAM: 8192 MiB for up to 4 parked conversations
parked 50978 tokens in 618.7 ms; bytes=2550090200      #  2.55 GB @ ~4.1 GB/s
```

Three things changed at once, and they explain a 200× gap:

1. **0.1.48 reserves the budget at startup**, from measured free RAM, so the park is not fighting
   the kernel for pages while it runs. On 0.1.45 the write rate collapsed once the snapshot passed
   ~600 MB, because the kernel was evicting the 42 GiB of mmap'd experts to make room — and those
   are precisely the pages decode then has to re-read.
2. **The rate is not one number even on 0.1.48.** Observed samples span ~1.5 GB/s to ~4.1 GB/s
   depending on snapshot size and how warm the RAM is. Treat 4 GB/s as the ceiling, not the mean.
3. **0.1.46's log has no conversation-cache line at all.** On that version the feature was never
   engaged, so the 22 MB/s sample cannot be used to argue anything about it.

What survives from C10 is the *shape* of the risk: snapshot cost is not linear, and a park that has
to evict experts is a park that will hit the watchdog. What does not survive is the absolute
conclusion "therefore off forever" — the version that ships with a startup-reserved budget does not
have that failure mode. Corrected in [`07-corrections.md`](07-corrections.md), C11.

## 3. DFlash2: the reason it cannot be used here

DFlash2 is a block-diffusion drafter, trained specifically for this target model, released after
the engine. It predicts a whole token block per forward pass, keeps per-position candidates, and
stitches one coherent path with a light selector. Greedy output is lossless — identical to the
target model. It reads the target's embedding and output head, so it is not a standalone model.

It fails on the first of three layers:

| layer | what was found | verdict |
|---|---|---|
| **① hard gate in code** | `generate.cpp:5478`: *"it is for one card and the CLI run (not --serve, --batch or a layer split) in this build"* — verified with `strings` against the built binary | **fatal** |
| ② VRAM | engine asks for ~1.2 GiB (pack 0.76 + buffers/KV ring 0.25 + draft head 0.2) and suggests `--vram-reserve-mib 1900`; free VRAM here is 874 MiB ⇒ short by ~330 MiB (~175 slots) | tight but reachable |
| ③ weights | public, Apache-2.0, packer is `tools/dflash2_pack.py` (numpy only, no torch). A third-party 776 MB `-Infernix` build is a **different format** and unusable | no obstacle |

Why single-card-only is not arbitrary: the drafter reads hidden states through verify taps at layers
**5, 15, 25, 35, 45**. With a layer split of 0–14 / 15–47, layer 5 lives on card 0 and the rest on
card 1. Collecting those taps means a cross-card transfer every step, and the engine has no such
path — so it disables the feature instead.

Upstream's own note in the code is not encouraging either: on a 12 GB NVIDIA card DFlash2 is slower
than MTP at every window size except for code-heavy prompts. Here VRAM is tighter still and there
are two cards.

**Options, none taken:**

| option | cost | verdict |
|---|---|---|
| A. Patch `serve` to drive the drafter per request, plus a cross-card hidden-state path | hundreds of lines of core changes in the decode loop, session management, cache/checkpoint interaction; re-do on every upstream release | not worth it |
| B. Single-card CLI, pure experiment | the 30B-class model needs ~47 GiB of experts; a single card would require re-packing to IQ1_M and hours of work, unrelated to daily use | pointless |
| C. Wait for upstream to allow `multi_gpu` / `--serve` | free, but even then VRAM is 330 MiB short | **the only sane option** |

## 4. The upgrade runbook (about 20 minutes, 2 minutes of downtime)

The binary alone is not enough — **`serve/` is the side that provides the conversation cache**, so
it must be swapped together with the executable.

1. **Freeze the build** out of the scratch worktree into a durable directory:

   ```bash
   sudo mkdir -p /opt/strata-0.1.48
   sudo cp -a build/strata            /opt/strata-0.1.48/build/
   sudo cp -a serve/                  /opt/strata-0.1.48/
   sudo cp -a strata_control/         /opt/strata-0.1.48/     # see 4.1
   sudo cp -a tools/                  /opt/strata-0.1.48/
   ```

2. **Point the two consumers at it.** The config's `exe` field and the unit's
   `ExecStart` (which runs `serve/server.py`) must both move:

   ```
   exe            : <old>/build/strata          → /opt/strata-0.1.48/build/strata
   ExecStart      : cd <old> && … serve/server.py → cd /opt/strata-0.1.48 && … serve/server.py
   expert_profile_save : <old>/expert-profile.bin → <new>/expert-profile.bin
   ```

   Nothing else. All 36 CLI arguments stay byte-identical — do not change two variables in one move.

3. **Isolate the learned profile.** Copy the old profile as a seed and write the new path to a
   different file, so a rollback finds the original untouched.

4. **Restart, then verify** with the checklist in §5.

### 4.1 Two traps that cost 23 restart attempts

```
ModuleNotFoundError: No module named 'strata_control'
```

0.1.48 promoted `strata_control` to a **repository-root package**; 0.1.46 did not have it at all.
Copying only `serve/` is not enough. And because the unit is `Restart=on-failure`, the missing
package produced a restart loop that hit the start-rate limit — after fixing the copy you must
`systemctl reset-failed <unit>` before `start`, or it refuses.

### 4.2 Log buffering

`strata serve:` lines land in the log late (Python block buffering); engine lines are real-time. To
check whether the conversation cache is live, read `/metrics` for `conversation_cache_mib` — do not
wait for the log line.

## 5. Acceptance checklist

| item | expected |
|---|---|
| `/health` | `loaded: true`, `max_context: 163840` |
| process `argv[0]` | the new binary path |
| slots / VRAM | 11,240 slots, ~21.1 GiB expert cache, `vram_free` ≈ 900 MiB |
| `/metrics` | `conversation_cache_mib = 8192`, `slots = 4` |
| profile path | the new isolated file |
| multi-turn decode (8K) | median ≈44–45, hit ≈0.95, reuse ≈99% |
| interleaved test (46K) | A1 ~72 s → A2 ~3.6 s → interrupt → **A3 reused 46,185 / 3.2 s** |
| kernel log | no SVM mapping failures, no OOM, no GPU reset |

## 6. Rollback (2 minutes)

```bash
sudo cp -a <cfg>.bak-promote-<stamp> /path/to/config.json
sudo cp -a <unit>.bak-promote-<stamp> /etc/systemd/system/<unit>.service
sudo systemctl daemon-reload
sudo systemctl restart <unit>
```

The 0.1.46 binary and its learned profile are left in place, untouched, for exactly this purpose.

## 7. Verdict

Upgrade. Not for speed — there is none — but because the conversation cache converts a 70-second
punishment for a normal habit (asking something else mid-session) into 3 seconds. The price is 2% on
prefill, which is about two seconds on a 68K prompt.

The wider lesson: **428 commits produced no measurable decode gain and one large usability fix.**
If you judge engine versions by benchmarks alone, you would have skipped this one.
