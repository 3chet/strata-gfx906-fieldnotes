#!/usr/bin/env bash
# apply_config_safely.sh — change ONE value in a live Strata config, restart, prove it.
#
# Born from taking my own production down twice. Both failures were process
# management, not the config. See ../docs/05-restart-runbook.md.
#
# Guarantees, in order:
#   1. snapshot verified before anything is touched
#   2. edit in place; assert exactly one position changed; audit for stray tokens
#   3. GATE 1: hash moved and the key re-reads from disk
#   4. stop the unit FIRST, then SIGTERM -> KILL, then poll until VRAM is really back
#   5. start; wait for /health 200 AND loaded:true
#   6. GATE 2: the value is in the RUNNING process's argv
#   7. GATE 3: a real request returns 200
#   8. any failure -> restore the snapshot and say so
#
# Nothing host-specific is baked in: configure via environment variables.
#
#   STRATA_CFG            path to the model config JSON            (required)
#   STRATA_FLAG           the flag to change, e.g. --max-context   (required)
#   STRATA_VALUE          the new value                            (required)
#   STRATA_UNIT           systemd unit name                        (optional)
#   STRATA_CONTAINER      container name, if the engine runs in one (optional)
#   STRATA_ENGINE_PATTERN pgrep pattern for the engine binary      (optional)
#   STRATA_SERVER_PATTERN pgrep pattern for the server script      (optional)
#   STRATA_GPU_MIB_CMD    command printing VRAM used in MiB, one line per GPU
#                                                                  (optional)
#   STRATA_HEALTH_URL     readiness probe returning 200            (optional)
#   STRATA_STATUS_URL     JSON status containing "loaded": true    (optional)
#   STRATA_CHAT_URL       a completions endpoint for Gate 3        (optional)
#   STRATA_MODEL          model name for Gate 3                    (optional)
#   STRATA_DRY_RUN=1      do everything except the restart
set -u

: "${STRATA_CFG:?set STRATA_CFG to the model config path}"
: "${STRATA_FLAG:?set STRATA_FLAG, e.g. --max-context}"
: "${STRATA_VALUE:?set STRATA_VALUE}"
STRATA_UNIT="${STRATA_UNIT:-}"
STRATA_CONTAINER="${STRATA_CONTAINER:-}"
STRATA_ENGINE_PATTERN="${STRATA_ENGINE_PATTERN:-strata}"
STRATA_SERVER_PATTERN="${STRATA_SERVER_PATTERN:-serve/server.py}"
STRATA_GPU_MIB_CMD="${STRATA_GPU_MIB_CMD:-}"
STRATA_HEALTH_URL="${STRATA_HEALTH_URL:-http://127.0.0.1:8080/health}"
STRATA_STATUS_URL="${STRATA_STATUS_URL:-http://127.0.0.1:8080/v1/status}"
STRATA_CHAT_URL="${STRATA_CHAT_URL:-http://127.0.0.1:8080/v1/chat/completions}"
STRATA_MODEL="${STRATA_MODEL:-strata}"
STRATA_DRY_RUN="${STRATA_DRY_RUN:-0}"
VRAM_FLOOR_MIB="${VRAM_FLOOR_MIB:-500}"

TS=$(date +%Y%m%d-%H%M%S)
SNAP="${STRATA_CFG}.rb-${TS}"

say() { printf '%s\n' "$*"; }
die() { say "!! FAIL: $*"; rollback; exit 1; }

# run a command inside the container when one is configured
in_ctr() {
    if [ -n "$STRATA_CONTAINER" ]; then
        docker exec "$STRATA_CONTAINER" "$@"
    else
        "$@"
    fi
}
pids_of() { in_ctr pgrep -f "$1" 2>/dev/null || true; }

vram_mib() {   # prints whitespace-separated MiB used per GPU; empty when unknown
    [ -n "$STRATA_GPU_MIB_CMD" ] || return 0
    eval "$STRATA_GPU_MIB_CMD" 2>/dev/null | grep -oE '[0-9]+' | paste -sd' ' -
}

rollback() {
    say "--- ROLLBACK to $SNAP ---"
    cp -a "$SNAP" "$STRATA_CFG" || say "  (snapshot copy failed)"
    say "  restored md5=$(md5sum "$STRATA_CFG" | cut -d' ' -f1)"
    [ "$STRATA_DRY_RUN" = "1" ] && { say "  dry run: not restarting"; return 0; }
    [ -n "$STRATA_UNIT" ] && systemctl restart "$STRATA_UNIT" 2>/dev/null
    return 0
}

# ---------- 1. snapshot -----------------------------------------------------
say "=== 1. snapshot ==="
cp -a "$STRATA_CFG" "$SNAP" || die "could not snapshot"
PRE_MD5=$(md5sum "$SNAP" | cut -d' ' -f1)
say "  $SNAP  md5=$PRE_MD5"
# verify the snapshot parses before relying on it
python3 - "$SNAP" <<'PY' || die "snapshot does not parse as JSON"
import json, sys
json.load(open(sys.argv[1]))
PY
say "  snapshot parses"

# ---------- 2. edit in place ------------------------------------------------
say
say "=== 2. edit ${STRATA_FLAG} in place ==="
python3 - "$STRATA_CFG" "$STRATA_FLAG" "$STRATA_VALUE" <<'PY' || die "edit failed"
import json, os, sys
cfg, flag, val = sys.argv[1], sys.argv[2], sys.argv[3]
c = json.load(open(cfg))
args = list(c["args"])

def audit(a):
    stray, expect = [], False
    for t in a:
        if t.startswith("--"): expect = True
        elif expect: expect = False
        else: stray.append(t)
    return stray

if audit(args):
    raise SystemExit("stray tokens before edit: %r" % audit(args))
if flag not in args:
    raise SystemExit("%s is not in args" % flag)

before = list(args)
i = args.index(flag)
old = args[i + 1]
args[i + 1] = val
diff = [k for k, (x, y) in enumerate(zip(before, args)) if x != y]
assert len(args) == len(before), "length changed"
assert diff == [i + 1], "unexpected change positions %r" % diff
if audit(args):
    raise SystemExit("stray tokens after edit: %r" % audit(args))

c["args"] = args
tmp = cfg + ".tmp"
json.dump(c, open(tmp, "w"), indent=2, ensure_ascii=False)
os.replace(tmp, cfg)
print("  %s: %s -> %s   (changed position %d only)" % (flag, old, val, i + 1))
PY

# ---------- 3. GATE 1: on disk ---------------------------------------------
say
say "=== 3. GATE 1: written and re-read ==="
python3 - "$STRATA_CFG" "$STRATA_FLAG" "$STRATA_VALUE" "$PRE_MD5" <<'PY' || die "GATE 1"
import hashlib, json, sys
cfg, flag, val, orig = sys.argv[1:5]
m = hashlib.md5(open(cfg, "rb").read()).hexdigest()
assert m != orig, "file unchanged - the write did not land (permissions?)"
c = json.load(open(cfg))
got = c["args"][c["args"].index(flag) + 1]
assert got == val, "re-read %r != %r" % (got, val)
print("  md5=%s  %s=%s" % (m, flag, got))
PY

if [ "$STRATA_DRY_RUN" = "1" ]; then
    say
    say "=== dry run: stopping here, restoring the snapshot ==="
    rollback
    exit 0
fi

# ---------- 4. stop + drain -------------------------------------------------
say
say "=== 4. stop + drain ==="
[ -n "$STRATA_UNIT" ] && { say "  systemctl stop $STRATA_UNIT"; systemctl stop "$STRATA_UNIT" 2>/dev/null || true; }

say "  SIGTERM the server (routes through Ctrl+C -> QUIT to the engine)"
for p in $(pids_of "$STRATA_SERVER_PATTERN"); do in_ctr kill -TERM "$p" 2>/dev/null || true; done
for _ in $(seq 1 30); do
    [ -z "$(pids_of "$STRATA_SERVER_PATTERN")" ] && [ -z "$(pids_of "$STRATA_ENGINE_PATTERN")" ] && break
    sleep 1
done
say "  KILL whatever survived"
for p in $(pids_of "$STRATA_ENGINE_PATTERN"); do in_ctr kill -KILL "$p" 2>/dev/null || true; done
for p in $(pids_of "$STRATA_SERVER_PATTERN"); do in_ctr kill -KILL "$p" 2>/dev/null || true; done

say "  waiting for VRAM to actually come back (GPU memory is reclaimed asynchronously)"
drained=1
for i in $(seq 1 120); do
    if [ -z "$(pids_of "$STRATA_SERVER_PATTERN")" ] && [ -z "$(pids_of "$STRATA_ENGINE_PATTERN")" ]; then
        if [ -z "$STRATA_GPU_MIB_CMD" ]; then
            say "  pids gone after ${i}s (no VRAM probe configured)"; drained=0; break
        fi
        v=$(vram_mib)
        over=0
        for m in $v; do [ "$m" -ge "$VRAM_FLOOR_MIB" ] && over=1; done
        if [ "$over" = "0" ]; then
            say "  drained after ${i}s: ${v} MiB (floor ${VRAM_FLOOR_MIB})"; drained=0; break
        fi
    fi
    sleep 1
done
[ "$drained" = "0" ] || { say "  VRAM did not drain: $(vram_mib 2>/dev/null) MiB"; die "drain timeout"; }

# ---------- 5. start + ready ------------------------------------------------
say
say "=== 5. start ==="
[ -n "$STRATA_UNIT" ] && { systemctl start "$STRATA_UNIT" || die "start failed"; }
ready=1
for _ in $(seq 1 300); do
    h=$(curl -s -m 4 -o /dev/null -w '%{http_code}' "$STRATA_HEALTH_URL" 2>/dev/null || true)
    j=$(curl -s -m 4 "$STRATA_STATUS_URL" 2>/dev/null || true)
    if [ "$h" = "200" ] && printf '%s' "$j" | grep -q '"loaded": true'; then ready=0; break; fi
    sleep 1
done
[ "$ready" = "0" ] || die "not ready in 300 s"
say "  ready (health 200 + loaded true)"

# ---------- 6. GATE 2: live argv -------------------------------------------
say
say "=== 6. GATE 2: the running process carries it ==="
EP=$(pids_of "$STRATA_ENGINE_PATTERN" | head -1)
[ -n "$EP" ] || die "no engine process found"
GOT=$(in_ctr sh -c "tr '\\0' '\\n' < /proc/$EP/cmdline" 2>/dev/null \
      | grep -A1 "^${STRATA_FLAG}\$" | tail -1)
say "  pid=$EP  ${STRATA_FLAG}=${GOT:-<absent>}"
[ "$GOT" = "$STRATA_VALUE" ] || die "live argv has '${GOT}', not '${STRATA_VALUE}'"
say "  GATE 2 OK"

# ---------- 7. GATE 3: serves ----------------------------------------------
say
say "=== 7. GATE 3: a real request ==="
code=$(curl -s -m 180 -o /dev/null -w '%{http_code}' "$STRATA_CHAT_URL" \
       -H 'Content-Type: application/json' \
       -d "{\"model\":\"${STRATA_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}],\"max_tokens\":16,\"temperature\":0}" \
       2>/dev/null || true)
say "  HTTP $code"
case "$code" in 2??) say "  GATE 3 OK" ;; *) die "request returned $code" ;; esac

say
say "=== APPLIED ==="
say "  config : $STRATA_CFG"
say "  md5    : $(md5sum "$STRATA_CFG" | cut -d' ' -f1)"
say "  restore: cp $SNAP $STRATA_CFG ${STRATA_UNIT:+&& systemctl restart $STRATA_UNIT}"
