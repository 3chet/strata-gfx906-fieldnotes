#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""measure_prefill.py -- measure prefill throughput without fooling yourself.

Why this exists: the prefix cache is exact, so the obvious way to measure prefill
(send the same prompt N times) measures reuse instead. Every repeat after the
first reads 5 tokens and reports a 0.07 s "prefill", which is a latency number
for a tiny workload, not a capacity number.

Five rules implemented here (see ../docs/08-prefill-rings-and-chunks.md):
  1. a unique nonce at the very front of every request, and `reused == 0` enforced
  2. throughput read from /metrics (prompt_read / prompt_ms), never the DONE line
  3. length measured in tokens from the response, never predicted from characters
  4. discard the first sample (page-cache / profile warm-up)
  5. report median + MAD + span, not the mean

Requirements: python3 stdlib only. Sends requests; writes nothing to the service.

Configuration (environment variables, nothing host-specific is baked in):
    STRATA_HOST=127.0.0.1
    STRATA_PORT=8080
    STRATA_MODEL=strata
    STRATA_API_KEY=            # optional
    STRATA_METRICS_URL=        # optional, defaults to http://HOST:PORT/metrics

Usage:
    python3 measure_prefill.py                        # 53000 CJK chars, 7 samples
    python3 measure_prefill.py --chars 90000           # ~52K tokens
    python3 measure_prefill.py --corpus my_text.txt    # your own fixture
    python3 measure_prefill.py --samples 7 --tag ring384 --out arm.csv

Warning: a prefill request is an evictor. If the server is also serving production
traffic, the first request after this run will be a cold full re-read. That is
expected; do not log it as production latency.
"""
import argparse
import json
import os
import random
import statistics
import sys
import time
import urllib.request


def env(name, default=""):
    return os.environ.get(name, default)


HOST = env("STRATA_HOST", "127.0.0.1")
PORT = env("STRATA_PORT", "8080")
MODEL = env("STRATA_MODEL", "strata")
API_KEY = env("STRATA_API_KEY", "")
BASE = "http://%s:%s" % (HOST, PORT)
METRICS_URL = env("STRATA_METRICS_URL", BASE + "/metrics")


# ---------------------------------------------------------------- fixture
# A synthetic CJK fixture, so the script runs without you preparing a corpus.
# It uses a fixed seed: two arms then see byte-identical text, which is what an
# A/B needs. For absolute numbers, use real prose (--corpus).
_WORDS = (
    "水利 工程 防汛 抗旱 河道 治理 堤防 水库 灌溉 排涝 供水 管网 改造 村庄 环境 整治 "
    "项目 建设 进度 质量 安全 监督 检查 验收 资料 台账 资金 拨付 预算 审计 绩效 评估 "
    "会议 部署 落实 推进 协调 调度 排查 隐患 整改 责任 主体 网格 管理 服务 群众 诉求 "
    "规划 编制 方案 论证 审批 备案 招标 施工 监理 竣工 移交 运维 巡查 监测 预警 应急 "
    "数据 共享 平台 系统 录入 报送 统计 分析 通报 排名 考核 培训 宣传 政策 解读 公开 "
    "镇街 社区 农户 企业 单位 部门 联合 执法 专项 行动 阶段 总结 报告 请示 批复 函件"
).split()


def synthetic_corpus(n_chars, seed=20260101):
    rnd = random.Random(seed)
    out, total = [], 0
    while total < n_chars:
        n = rnd.randint(8, 22)
        sent = "".join(rnd.choice(_WORDS) for _ in range(n)) + "。"
        out.append(sent)
        total += len(sent)
    return "".join(out)[:n_chars]


# ---------------------------------------------------------------- http
def _req(url, payload=None, timeout=900):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data,
                                 headers={"Content-Type": "application/json"})
    if API_KEY:
        req.add_header("Authorization", "Bearer " + API_KEY)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def metrics():
    return _req(METRICS_URL, None, timeout=30)


def wait_idle(limit=120):
    """Do not measure behind someone else's request; it halves both numbers."""
    for _ in range(limit):
        live = metrics().get("live") or {}
        if live.get("state") in (None, "idle") and not (live.get("queued") or 0):
            return True
        time.sleep(2)
    return False


def last_request(min_tokens):
    """The most recent /metrics entry for a request at least min_tokens long."""
    reqs = metrics().get("requests") or []
    for q in reqs:
        if (q.get("prompt_tokens") or 0) >= min_tokens:
            return q
    return None


# ---------------------------------------------------------------- stats
def mad(values):
    if not values:
        return 0.0
    m = statistics.median(values)
    return statistics.median([abs(v - m) for v in values])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", help="UTF-8 text file to use as the fixture")
    ap.add_argument("--chars", type=int, default=53000,
                    help="fixture length in characters (default 53000 CJK ~= 32K tokens)")
    ap.add_argument("--samples", type=int, default=7, help="measured samples (first is discarded)")
    ap.add_argument("--max-tokens", type=int, default=16)
    ap.add_argument("--tag", default="prefill")
    ap.add_argument("--out", help="CSV output path")
    ap.add_argument("--min-free-mib", type=int, default=0,
                    help="abort if engine vram_free_mib drops below this (0 = ignore)")
    args = ap.parse_args()

    if args.corpus:
        text = open(args.corpus, encoding="utf-8", errors="replace").read()[:args.chars]
        src = os.path.basename(args.corpus)
    else:
        text = synthetic_corpus(args.chars)
        src = "synthetic(seed=20260101)"
    text = text.strip()
    print("[%s] fixture: %s, %d chars" % (args.tag, src, len(text)), flush=True)
    print("[%s] tokens are NOT predicted here -- they are read from the response "
          "and from /metrics" % args.tag, flush=True)

    rows, discarded = [], []
    for i in range(args.samples + 1):
        if not wait_idle():
            print("  sample %d: server never went idle, skipping" % (i + 1), flush=True)
            continue
        if args.min_free_mib:
            free = (metrics().get("engine") or {}).get("vram_free_mib") or 0
            if free and free < args.min_free_mib:
                print("  ABORT: vram_free %d MiB < %d MiB" % (free, args.min_free_mib), flush=True)
                break

        # Rule 1: a unique, NON-ZERO prefix. A nonce of all zeros is normalised away
        # by some tokenisers and then the whole prompt matches as a prefix.
        nonce = "[probe %s-%d-%06d]" % (args.tag, i + 1, int(time.time() * 1000) % 1000000)
        t0 = time.time()
        try:
            resp = _req(BASE + "/v1/chat/completions", {
                "model": MODEL,
                "messages": [{"role": "user",
                              "content": nonce + "\n" + text + "\n\nSummarise the text above in one sentence."}],
                "max_tokens": args.max_tokens,
                "temperature": 0,
            })
        except Exception as e:                                    # noqa: BLE001
            print("  sample %d: request failed: %s" % (i + 1, e), flush=True)
            time.sleep(5)
            continue
        wall = time.time() - t0
        usage = resp.get("usage") or {}
        ptok = usage.get("prompt_tokens") or 0

        time.sleep(1.0)
        q = last_request(max(1, int(ptok * 0.8)))
        if not q:
            print("  sample %d: no matching /metrics entry (prompt_tokens=%s)" % (i + 1, ptok), flush=True)
            continue

        total = q.get("prompt_tokens") or ptok
        read = q.get("prompt_read", total)
        pms = q.get("prompt_ms") or 0.0
        if read < total * 0.9:
            # Rule 1 enforced: anything less than a full read is not a prefill sample.
            print("  sample %d: INVALID reused=%d/%d -- prefix cache hit, counted as a "
                  "reuse measurement, not a prefill measurement" % (i + 1, total - read, total), flush=True)
            discarded.append({"sample": i + 1, "prompt_tokens": total, "read": read})
            continue
        tps = read / (pms / 1000.0) if pms else 0.0
        row = {"sample": i + 1, "prompt_tokens": total, "read": read,
               "prompt_ms": round(pms, 1), "prefill_tps": round(tps, 1),
               "decode_tps": round(q.get("decode_tok_s") or 0, 1),
               "wall_s": round(wall, 1), "hit_pct": q.get("hit_rate")}
        print("  sample %d: %d tok (%d read) %.2f s = %.1f tok/s | wall %.1f s | hit %s"
              % (i + 1, total, read, pms / 1000.0, tps, wall, q.get("hit_rate")), flush=True)

        # Rule 4: the first full-read sample pays for cold page cache.
        if not rows and i == 0:
            discarded.append(row)
            print("    ^ discarded as the first sample (cold page cache / profile warm-up)", flush=True)
        else:
            rows.append(row)
        time.sleep(2)

    if len(rows) < 2:
        print("\n[%s] not enough valid samples (%d). Nothing to report."
              % (args.tag, len(rows)), flush=True)
        return 1

    vals = [r["prefill_tps"] for r in rows]
    med = statistics.median(vals)
    print("\n[%s] n=%d  median=%.1f  mean=%.1f  MAD=%.1f  min=%.1f  max=%.1f  span=%.1f"
          % (args.tag, len(rows), med, statistics.mean(vals), mad(vals),
             min(vals), max(vals), max(vals) - min(vals)), flush=True)
    print("[%s] prompt_tokens=%d  decode median=%s"
          % (args.tag, rows[0]["prompt_tokens"],
             statistics.median([r["decode_tps"] for r in rows if r["decode_tps"]])), flush=True)
    if discarded:
        print("[%s] discarded %d sample(s): %s"
              % (args.tag, len(discarded), [d.get("sample") for d in discarded]), flush=True)

    if args.out:
        cols = ["sample", "prompt_tokens", "read", "prompt_ms", "prefill_tps",
                "decode_tps", "wall_s", "hit_pct"]
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write("tag," + ",".join(cols) + "\n")
            for r in rows:
                fh.write(args.tag + "," + ",".join(str(r.get(c, "")) for c in cols) + "\n")
        print("[%s] wrote %s" % (args.tag, args.out), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
