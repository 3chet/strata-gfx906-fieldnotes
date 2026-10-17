#!/usr/bin/env bash
# measure_steady.sh — measure decode throughput without the cold-start bias.
#
# Why this exists: decode climbs over ~5 requests after every restart AND after
# every workload change. Measuring from sample 1 gives a number 30-40% too low,
# and the bias differs per arm, so an A/B built on it produces confident nonsense.
# See ../docs/02-methodology.md.
#
# Requirements: bash, curl, python3, and a running Strata server.
# No writes to the service. Sends requests only.
#
# Configuration is via environment variables — nothing about a particular host is
# baked in. Set at least STRATA_URL (or STRATA_HOST/STRATA_PORT).
set -u

STRATA_HOST="${STRATA_HOST:-127.0.0.1}"
STRATA_PORT="${STRATA_PORT:-8080}"
STRATA_URL="${STRATA_URL:-http://${STRATA_HOST}:${STRATA_PORT}/v1/chat/completions}"
STRATA_STATUS_URL="${STRATA_STATUS_URL:-http://${STRATA_HOST}:${STRATA_PORT}/v1/status}"
STRATA_API_KEY="${STRATA_API_KEY:-}"          # optional; many local servers need none
STRATA_MODEL="${STRATA_MODEL:-strata}"
STRATA_LOG="${STRATA_LOG:-}"                  # optional: engine log, enables hit-rate capture
PRE="${PRE:-5}"                               # discarded preconditioning requests
SAMPLES="${SAMPLES:-8}"                       # measured requests
OUT="${OUT:-./steady-$(date +%Y%m%d-%H%M%S).csv}"
WORKLOADS="${WORKLOADS:-count echo prose}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

auth=()
[ -n "$STRATA_API_KEY" ] && auth=(-H "Authorization: Bearer ${STRATA_API_KEY}")

# ---------- workloads -------------------------------------------------------
# Three shapes with different draft acceptance, so a setting that only helps one
# of them is visible instead of averaged away.
python3 - "$TMP" "$STRATA_MODEL" <<'PY'
import json, os, sys
d, model = sys.argv[1], sys.argv[2]
words = ("harbour lantern gravel mercury cedar thistle quartz narrow meadow copper lantern "
         "shallow braided amber hollow juniper mosaic tundra willow flint cinder marble").split()
sents = []
for i in range(14):
    w = [words[(i*7 + j*3) % len(words)] for j in range(9)]
    sents.append(" ".join(w).capitalize() + ".")
passage = " ".join(sents)
specs = {
    # best case for a lookup drafter: the answer repeats the prompt
    "echo": {"content": "Here is a passage:\n\n" + passage +
                         "\n\nTask: repeat the passage above exactly, word for word, "
                         "then write END on its own line.",
             "max_tokens": 192},
    # normal writing: little to look up
    "prose": {"content": "Write about 160 words of original prose describing the sound of rain on a "
                          "tin roof at night. Use varied vocabulary and do not repeat sentences.",
              "max_tokens": 192},
    # highly repetitive output
    "count": {"content": "Count slowly from 1 to 60, separated by spaces, nothing else.",
              "max_tokens": 128},
}
for name, s in specs.items():
    json.dump({"model": model,
               "messages": [{"role": "user", "content": s["content"]}],
               "max_tokens": s["max_tokens"], "temperature": 0},
              open(os.path.join(d, "w_%s.json" % name), "w"))
print("workloads: " + " ".join(sorted(specs)))
PY

# ---------- preflight -------------------------------------------------------
status="$(curl -s -m 8 "$STRATA_STATUS_URL" || true)"
printf '%s' "$status" | grep -q '"loaded": true' \
    || { echo "!! server not ready at $STRATA_STATUS_URL" >&2; exit 1; }
echo "server ready"
printf '%s' "$status" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("  cache_max_tokens:", d.get("cache_max_tokens"))
print("  concurrency     :", d.get("concurrency"))' 2>/dev/null || true

# ---------- one request -----------------------------------------------------
# Prints: reused gen ms tps accepted total hit
one_request() {
    local file="$1" b4 out line hit=""
    [ -n "$STRATA_LOG" ] && b4=$(wc -l < "$STRATA_LOG" 2>/dev/null || echo 0) || b4=0
    out=$(curl -s -m 600 "$STRATA_URL" -H 'Content-Type: application/json' \
              "${auth[@]}" --data-binary @"$file")
    sleep 1
    if [ -n "$STRATA_LOG" ]; then
        line=$(sed -n "$((b4+1)),\$p" "$STRATA_LOG" 2>/dev/null | grep 'generated in' | tail -1)
        hit=$(sed -n "$((b4+1)),\$p" "$STRATA_LOG" 2>/dev/null \
              | grep -o 'expert cache hit rate: [0-9.]*' | tail -1 | grep -o '[0-9.]*$')
    else
        # no log: fall back to the API's own usage block
        line=$(printf '%s' "$out" | python3 -c '
import json,sys
try:
    u=json.load(sys.stdin).get("usage") or {}
    print("generated %s tokens in %s ms" % (u.get("completion_tokens"), u.get("completion_time_ms")))
except Exception: pass' 2>/dev/null)
    fi
    python3 - "$line" "${hit:--}" <<'PY'
import re, sys
l = sys.argv[1]
m = re.search(r'tokens = (\d+) reused', l)
g = re.search(r'(\d+) generated in (\d+) ms \(([\d.]+) tok/s\)', l)
g2 = re.search(r'generated (\d+) tokens in (\d+) ms', l)
d = re.search(r'drafts accepted (\d+) of (\d+)', l)
if g:
    gen, ms, tps = g.group(1), g.group(2), g.group(3)
elif g2:
    gen, ms = g2.group(1), g2.group(2)
    tps = "%.1f" % (1000.0 * int(gen) / int(ms)) if int(ms) else "-"
else:
    gen = ms = tps = "-"
print(m.group(1) if m else '-', gen, ms, tps,
      d.group(1) if d else '-', d.group(2) if d else '-', sys.argv[2])
PY
}

echo "workload,phase,sample,reused,generated,ms,tps,accepted,total,hit" > "$OUT"
echo "writing to $OUT"

# ---------- the measurement -------------------------------------------------
for wl in $WORKLOADS; do
    f="$TMP/w_${wl}.json"
    [ -f "$f" ] || { echo "  unknown workload: $wl" >&2; continue; }
    echo
    echo "--- $wl: $PRE discarded, then $SAMPLES measured ---"
    for i in $(seq 1 "$PRE"); do
        read -r RE GEN MS TPS ACC TOT HIT <<<"$(one_request "$f")"
        echo "  pre$i  ${TPS} tok/s  hit=${HIT}%"
        echo "$wl,pre,$i,$RE,$GEN,$MS,$TPS,$ACC,$TOT,$HIT" >> "$OUT"
    done
    for i in $(seq 1 "$SAMPLES"); do
        read -r RE GEN MS TPS ACC TOT HIT <<<"$(one_request "$f")"
        printf '  m%-2s %6s tok/s  hit=%s%%\n' "$i" "$TPS" "$HIT"
        echo "$wl,meas,$i,$RE,$GEN,$MS,$TPS,$ACC,$TOT,$HIT" >> "$OUT"
    done
done

# ---------- summary ---------------------------------------------------------
echo
python3 - "$OUT" <<'PY'
import csv, statistics as st, sys
rows = list(csv.DictReader(open(sys.argv[1])))
print("%-7s %8s %8s %8s  %s" % ("load", "median", "MAD", "n", "hit rate (median)"))
for wl in ("count", "echo", "prose"):
    v = [float(r["tps"]) for r in rows
         if r["wl"] == wl and r["phase"] == "meas" and r["tps"] not in ("-", "")]
    if not v:
        continue
    med = st.median(v)
    mad = st.median([abs(x - med) for x in v])
    h = [float(r["hit"]) for r in rows
         if r["wl"] == wl and r["phase"] == "meas" and r["hit"] not in ("-", "")]
    print("%-7s %8.2f %8.2f %8d  %s" % (wl, med, mad, len(v),
          ("%.2f%%" % st.median(h)) if h else "n/a"))
print()
print("Reminder: this is ONE arm. To judge a change you need two arms of each")
print("config on separate restarts, and the difference between the same-config")
print("arms is your resolution. See docs/02-methodology.md.")
PY
