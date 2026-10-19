# Restart runbook — and the way `systemctl restart` can take your service down

I took my own production instance down twice while applying a one-line config change. Both failures were
**process management**, not the config. Here is what happened and the sequence that works.

---

## What goes wrong

The unit on this box looks like this:

```ini
[Service]
Type=simple
ExecStartPre=/usr/bin/docker start <container>
ExecStart=/usr/bin/docker exec <container> bash -c '... exec python3 serve/server.py --engine strata --config <cfg> --port <port> >> <log> 2>&1'
ExecStop=-/usr/bin/docker exec <container> pkill -f 'serve/server.py'
Restart=on-failure
RestartSec=15
KillMode=control-group
```

`ExecStop` kills **`server.py` only**. The engine (`<engine binary> --serve …`) is a **child process**
and can survive. A `docker exec` that is killed does not necessarily signal the process inside the
container.

### Failure 1 — the old engine keeps the port

`systemctl restart` → old `server.py` killed, **old engine survives**, still holding port <port> and the
GPU. The new instance starts, tries to bind, and:

```
server.py: error: port <port> is already in use - is Strata (or another server) already running?
```

…then exits `status=2`. With `Restart=on-failure`, systemd retries every 15 s — and every retry hits the
same orphaned engine. It looks like a broken config; it is not.

**The tell:** the server log already contains a successful line from the previous attempt:

```
ready: http://127.0.0.1:<port>/v1  (... context 131072 tokens)
```

The new config *worked*. It just could not bind.

### Failure 2 — the readiness gate looked at the wrong things, too early

After fixing the kill, I gated on "no listener on <port>" and "VRAM released", and it **still** aborted.
Two separate mistakes:

1. **GPU memory is reclaimed asynchronously.** At the moment the gate ran, VRAM still read
   **10.7 GB / 9.3 GB** with zero processes alive. Seconds later it was **10.8 MB / 10.8 MB**. The gate
   measured too early.
2. **A lingering LISTEN socket is not a blocker.** The server sets `allow_reuse_address` (Python's
   `http.server` on non-Windows), so a stale socket from a dead process does not prevent the bind.

**Lesson:** gate on *resources actually released*, not on *things you expect to have vanished*.

---

## The sequence that works

```bash
# 1. stop the UNIT first — otherwise systemd races you with Restart=on-failure
sudo systemctl stop <unit>

# 2. ask the container to quit cleanly.
#    server.py ignores Python's default SIGTERM behaviour and routes it through Ctrl+C,
#    which sends QUIT to the engine — so this is the graceful path.
for p in $(docker exec <container> pgrep -f 'serve/server.py'); do
    docker exec <container> kill -TERM "$p"
done
# wait, then escalate only if needed
for i in $(seq 1 30); do
    [ -z "$(docker exec <container> pgrep -f 'serve/server.py')" ] && \
    [ -z "$(docker exec <container> pgrep -f '<engine binary>')" ] && break
    sleep 1
done
for p in $(docker exec <container> pgrep -f '<engine binary>'); do
    docker exec <container> kill -KILL "$p"
done

# 3. GATE: poll until VRAM is actually back on BOTH cards
for i in $(seq 1 120); do
    read -r v0 v1 <<<"$(rocm-smi --showmeminfo vram | grep 'Used Memory (B)' | grep -oE '[0-9]{6,}' | head -2 | awk '{printf "%d %d\n",$1/1048576,$2/1048576}')"
    if [ "${v0:-99999}" -lt 500 ] && [ "${v1:-99999}" -lt 500 ] && \
       [ -z "$(docker exec <container> pgrep -f 'serve/server.py')" ] && \
       [ -z "$(docker exec <container> pgrep -f '<engine binary>')" ]; then
        echo "drained after ${i}s: ${v0}/${v1} MiB"; break
    fi
    sleep 1
done

# 4. start, and wait for a real readiness signal
sudo systemctl start <unit>
for i in $(seq 1 300); do
    h=$(curl -s -m 4 -o /dev/null -w '%{http_code}' http://127.0.0.1:<port>/health || true)
    j=$(curl -s -m 4 http://127.0.0.1:<port>/v1/status || true)
    [ "$h" = "200" ] && printf '%s' "$j" | grep -q '"loaded": true' && break
    sleep 1
done
```

On this box the drain took **2 seconds** — the wait is cheap; guessing is expensive.

---

## Proving the config change actually landed

Three gates, in this order. Each one catches a different failure.

**Gate 1 — on disk.** Hash must move, and the key must re-read:

```bash
python3 - <<'PY'
import json, hashlib, sys
cfg, new, orig = sys.argv[1], sys.argv[2], sys.argv[3]
m = hashlib.md5(open(cfg,'rb').read()).hexdigest()
assert m != orig, "ABORT: file unchanged — the write did not land"
c = json.load(open(cfg))
assert c["args"][c["args"].index("--max-context")+1] == new, "ABORT: key not on disk"
PY
```

A root-owned config written by a non-root helper raises `PermissionError`, which is easy to swallow —
you then run a whole arm against an unmodified service and report "no difference".

**Gate 2 — in the running process.** The config file is not the truth; argv is:

```bash
tr '\0' '\n' < /proc/<engine-pid>/cmdline | grep -A1 '^--max-context$'
```

**Gate 3 — the service actually serves.** `/health` 200 is not enough; send a real request:

```bash
curl -s http://127.0.0.1:<port>/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"<model>","messages":[{"role":"user","content":"Say OK"}],"max_tokens":16,"temperature":0}'
```

---

## Editing a live JSON config without corrupting it

Edit **in place**, and assert that only one position changed. Rebuilding the array from a filter is how a
flag gets separated from its value:

```python
before = list(c["args"])
c["args"][i] = new_value
diff = [k for k,(x,y) in enumerate(zip(before, c["args"])) if x != y]
assert diff in ([], [i]), f"unexpected change positions {diff}"   # [] = already correct
assert len(c["args"]) == len(before)
```

And a structural guard for strays — tokens that are neither a flag nor a flag's value:

```python
def audit(args):
    stray, expect = [], False
    for t in args:
        if t.startswith("--"): expect = True
        elif expect: expect = False
        else: stray.append(t)
    return stray
assert audit(args) == []
```

Write atomically (`tmp` + `os.replace`) and re-read.

---

## Rollback artefacts

Snapshots are cheap; keep several, timestamped, and **never let a script overwrite the restore source**:

```
<config>.rb-YYYYMMDD-HHMMSS      # one per attempt, byte-identical pre-image
<rollback-dir>/config.production.json     # independent copy
<rollback-dir>/owner_mode.txt             # owner + mode, to restore exactly
<rollback-dir>/recovery-context.txt       # argv, env, unit, drop-ins, /v1/status
```

Verify before you need it: `cmp` the snapshot against a copy, and confirm it parses as a valid config.

Rollback is then two commands:

```bash
sudo cp <config>.rb-<stamp> <config>
sudo systemctl restart <unit>
```

---

## Checklist

```
[ ] snapshot taken and verified (hash + parses)
[ ] edit in place; only the intended position changed; audit clean
[ ] Gate 1: md5 moved, key re-read from disk
[ ] systemctl stop FIRST
[ ] SIGTERM server.py, wait, KILL engine
[ ] Gate: VRAM < 500 MiB on BOTH cards AND no pids  (do not gate on the port)
[ ] start; wait for /health 200 AND loaded:true
[ ] Gate 2: live argv carries the new value
[ ] Gate 3: a real request returns 200
[ ] rollback command written down before starting
```
