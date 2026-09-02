#!/usr/bin/env python3
"""Where did the status actually come from, and how often was it in a position to
be right? Reads the NotchDial debug log and reports, per app, how much of the time
the Accessibility signal was usable, how often the tree came back empty, and how
often each state was published — so an argument about "it never matches" can be
had over numbers instead of impressions."""
import os, re, sys
from collections import Counter, defaultdict
from datetime import datetime

paths = sys.argv[1:] or ["~/Library/Logs/NotchDial/status.log"]
lines = []
for p in paths:
    with open(os.path.expanduser(p), errors="replace") as f:
        lines += f.readlines()

names = {"0": "Codex", "1": "Cursor", "2": "Claude"}
tot = 0
usable = Counter(); zero = Counter(); busy = Counter(); trunc = Counter()
stop_named = Counter(); stop_idle = Counter()
publishes = []
starts = 0
first = last = None
for ln in lines:
    ts = ln[:20]
    if "START" in ln: starts += 1
    if " PUBLISH " in ln:
        publishes.append((ts, ln.split("PUBLISH ", 1)[1].strip()))
    if "AX res" not in ln: continue
    tot += 1
    first = first or ts; last = ts
    m = re.search(r"usable=\[([^\]]*)\]", ln)
    ids = {x.strip() for x in m.group(1).split(",") if x.strip()} if m else set()
    for i in "012":
        usable[i] += i in ids
        mm = re.search(r'"%s:(BUSY|idle)/(\d+)n(~?)"' % i, ln)
        if mm:
            if mm.group(2) == "0": zero[i] += 1
            if mm.group(1) == "BUSY": busy[i] += 1
            if mm.group(3): trunc[i] += 1
    o = re.search(r"open=\[([^\]]*)\]", ln)
    if o:
        for i in "012":
            if re.search(r"%s:STOP/" % i, o.group(1)): stop_named[i] += 1
            elif re.search(r"%s:idle/" % i, o.group(1)): stop_idle[i] += 1

print(f"时间范围 {first} → {last}   扫描 {tot} 轮 ≈ {tot/3600:.1f} 小时   重启 {starts} 次\n")
print(f"{'':8s} {'AX可用':>7s} {'读到0节点':>9s} {'截断~':>7s} {'BUSY':>7s} {'停止键在':>8s} {'停止键无':>8s}")
for i in "012":
    def pct(c): return f"{c[i]*100/tot:5.1f}%"
    print(f"{names[i]:8s} {pct(usable):>7s} {pct(zero):>9s} {pct(trunc):>7s} {pct(busy):>7s} {pct(stop_named):>8s} {pct(stop_idle):>8s}")

print(f"\n状态发布 {len(publishes)} 次。每个 app 各状态出现次数：")
per = defaultdict(Counter)
for ts, p in publishes:
    for i in "012":
        m = re.search(r"%s=(\w+)" % i, p)
        if m: per[i][m.group(1)] += 1
for i in "012":
    print(f"  {names[i]:7s} {dict(per[i])}")

def stretches(i):
    out = []; cur = None
    for ts, p in publishes:
        m = re.search(r"%s=(\w+)" % i, p)
        st = m.group(1) if m else None
        t = datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")
        if st == "working" and cur is None: cur = t
        elif st != "working" and cur is not None:
            out.append((t - cur).total_seconds()); cur = None
    return out
print("\n每段 working 持续时长（秒）— 很短的就是闪烁：")
for i in "012":
    s = stretches(i)
    if not s: print(f"  {names[i]:7s} (无)"); continue
    s.sort()
    short = sum(1 for x in s if x < 5)
    print(f"  {names[i]:7s} n={len(s)}  <5s: {short} ({short*100//len(s)}%)  中位 {s[len(s)//2]:.0f}s  最长 {s[-1]:.0f}s")
print(f"\n总 PUBLISH/小时: {len(publishes)/max(1e-9, tot/3600):.1f}")
