#!/usr/bin/env python3
"""Same-prefix multi-turn probe: what decode actually is, once the prompt is warm.

Why this exists. A benchmark that rotates unrelated prompts measures a *cold* prefix --
0% prompt reuse, a full prefill every round, expert-cache hit around 0.88. Production is
the opposite: one conversation, one turn appended at a time, ~99% reuse, hit around 0.96.
The rotation harness reads ~13% low and it reads low in the same direction every time, so
it will happily "prove" that a configuration is worse than it is.

This script answers the three questions the rotation harness cannot:

  1. How much does `reused` actually recover? (It reads 0 in `totals` unless you send a
     second turn on the same prefix -- no earlier harness ever did.)
  2. Is the 0.88 hit rate real, or an artifact of the harness?
  3. Is decode really 38, or is 38 the cold-start floor?

Usage:
    python3 multiturn_probe.py --base-url http://127.0.0.1:8080 --model my-model \
        --sys-k 8 --turns 6 --out 200

    --sys-k is in *thousands of tokens*; the script repeats a CJK filler passage until the
    system message is roughly that long (0.6 tokens per character for CJK). Use one run at
    8 and one at 55 to see the length dependence.

Reads `reused`, `decode_tok_s` and `hit_rate` from the engine's /metrics after every turn.
Turn 1 is reported but excluded from the steady-state summary: it pays the full prefill.
"""
import argparse
import json
import statistics
import time
import urllib.request

FILLER = (
    '基层治理的核心在于把矛盾化解在萌芽状态。网格化管理通过划定责任片区、配备专职网格员，'
    '实现信息采集、隐患上报、纠纷调处的闭环。数字化平台则将分散的台账整合为统一数据库，'
    '使事件流转可追溯、处置时限可考核。但技术只是工具，真正的难点在于人的协同：'
    '部门之间的数据壁垒、条块之间的权责交叉、干部之间的考核压力，都会让系统空转。'
    '因此制度设计必须与技术改造同步推进，既要有刚性约束，也要留出弹性空间。'
)


def get_metrics(base_url):
    with urllib.request.urlopen(base_url.rstrip('/') + '/metrics', timeout=10) as r:
        return json.loads(r.read().decode())


def post(base_url, model, messages, max_tokens, timeout=900):
    body = json.dumps({
        'model': model,
        'messages': messages,
        'max_tokens': max_tokens,
        'temperature': 0,
    }).encode()
    req = urllib.request.Request(
        base_url.rstrip('/') + '/v1/chat/completions',
        data=body,
        headers={'Content-Type': 'application/json'},
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read().decode()
    return time.time() - t0, json.loads(raw)


def latest_request(metrics):
    rs = metrics.get('requests') or []
    return rs[0] if rs else {}


def summarise(rows, key, fmt='{:.1f}'):
    vals = [r[key] for r in rows if r.get(key) is not None]
    if not vals:
        return None
    med = statistics.median(vals)
    return 'median ' + fmt.format(med) + f'  range {fmt.format(min(vals))}~{fmt.format(max(vals))}'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base-url', default='http://127.0.0.1:8080')
    ap.add_argument('--model', required=True)
    ap.add_argument('--label', default='mt')
    ap.add_argument('--sys-k', type=int, default=8, help='system prompt size, in thousands of tokens')
    ap.add_argument('--turns', type=int, default=6)
    ap.add_argument('--out', type=int, default=200, help='max_tokens per turn')
    ap.add_argument('--jsonl', default='multiturn-results.jsonl')
    args = ap.parse_args()

    # 0.6 tokens per CJK character, the measured ratio for this tokenizer.
    n = max(1, int(args.sys_k * 1000 / (len(FILLER) * 0.6)))
    system = ('You are an assistant. Reference material follows.\n' + (FILLER + '\n') * n)
    msgs = [{'role': 'system', 'content': system}]

    print(f'=== {args.label}: system ~{args.sys_k}K tokens, {args.turns} turns, '
          f'{args.out} tok each ===', flush=True)
    rows = []
    for i in range(1, args.turns + 1):
        msgs.append({'role': 'user', 'content': f'Turn {i}: summarise the material in two sentences.'})
        try:
            wall, rj = post(args.base_url, args.model, msgs, args.out)
        except Exception as e:  # noqa: BLE001 - a failed turn should end the run, not crash it
            print(f'  turn{i}: ERROR {e!r}', flush=True)
            break
        usage = rj.get('usage') or {}
        answer = (rj.get('choices') or [{}])[0].get('message', {}).get('content', '')
        m = latest_request(get_metrics(args.base_url))
        rec = {
            'turn': i,
            'prompt_tokens': usage.get('prompt_tokens'),
            'completion_tokens': usage.get('completion_tokens'),
            'reused': m.get('reused'),
            'decode_tok_s': m.get('decode_tok_s'),
            'hit_rate': m.get('hit_rate'),
            'wall_s': round(wall, 1),
        }
        rows.append(rec)
        print(f"  turn{i}: pt={rec['prompt_tokens']} out={rec['completion_tokens']} "
              f"reused={rec['reused']} hit={rec['hit_rate']} "
              f"decode={rec['decode_tok_s']} wall={rec['wall_s']}s", flush=True)
        msgs.append({'role': 'assistant', 'content': answer})

    if args.jsonl:
        with open(args.jsonl, 'a', encoding='utf-8') as f:
            for r in rows:
                f.write(json.dumps({'label': args.label, **r}, ensure_ascii=False) + '\n')

    steady = rows[1:] if len(rows) > 1 else rows
    print('\n=== steady state (turn 1 dropped: it pays the full prefill) ===')
    for key, fmt in (('decode_tok_s', '{:.1f}'), ('hit_rate', '{:.3f}')):
        s = summarise(steady, key, fmt)
        if s:
            print(f'  {key:12s} {s}')
    reused = sum(r['reused'] or 0 for r in steady)
    prompt = sum(r['prompt_tokens'] or 0 for r in steady)
    if prompt:
        print(f'  reuse rate   {reused} / {prompt} tokens = {reused / prompt * 100:.1f}%')
    print('MT_DONE')


if __name__ == '__main__':
    main()
