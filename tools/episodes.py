#!/usr/bin/env python3
"""Working episodes in status.log, by source: who said "working", for how long, and
whether it ended in a stamp. Answers "why did the notch light up when I did nothing".
usage: episodes.py ~/Library/Logs/NotchDial/status.log [--since 2026-09-02T20:00]"""
import re, sys
from datetime import datetime

path = sys.argv[1]
since = None
if '--since' in sys.argv:
    since = datetime.fromisoformat(sys.argv[sys.argv.index('--since') + 1])

ts_re = re.compile(r'^(\S+)Z (.*)$')
names = {0: 'Codex/ChatGPT', 1: 'Cursor', 2: 'Claude'}
# per-second observations from AX lines
cur = {}          # id -> dict(busy_ax, net, usable, nodes)
episodes = []     # (id, start, end, source_set, ax_seen_readable, ended_with)
open_ep = {}      # id -> [start, sources set, readable_seen]
last_ts = None
publish_states = {}
stamps = {0: 0, 1: 0, 2: 0}
first = last = None
n_lines = 0

def close(id_, ts, how):
    ep = open_ep.pop(id_, None)
    if ep: episodes.append((id_, ep[0], ts, ep[1], ep[2], how))

for line in open(path, encoding='utf-8', errors='replace'):
    m = ts_re.match(line)
    if not m: continue
    ts = datetime.fromisoformat(m.group(1))
    if since and ts < since: continue
    first = first or ts; last = ts; n_lines += 1
    body = m.group(2)
    if body.startswith('AX res='):
        res = dict((int(a), (b, int(c))) for a, b, c in re.findall(r'"(\d):(BUSY|idle)/(\d+)n', body))
        usable = set(int(x) for x in re.findall(r'usable=\[([^\]]*)\]', body)[0].split(', ') if x) if 'usable=[' in body else set()
        busy = set(int(x) for x in re.findall(r'busy=\[([^\]]*)\]', body)[0].split(', ') if x) if 'busy=[' in body else set()
        netm = re.findall(r' net=\[([^\]]*)\]', body)
        net = set(int(x) for x in netm[0].split(', ') if x) if netm else set()
        for id_ in (0, 1, 2):
            working = id_ in busy or (id_ in net and id_ not in usable)
            src = ('ax' if id_ in busy else 'net') if working else None
            if working:
                if id_ not in open_ep:
                    open_ep[id_] = [ts, set(), False]
                open_ep[id_][1].add(src)
                if id_ in res and res[id_][1] >= 20: open_ep[id_][2] = True
            elif id_ in open_ep:
                close(id_, ts, 'quiet')
    elif body.startswith('PUBLISH'):
        st = dict((int(a), b) for a, b in re.findall(r'(\d)=(\w+)', body))
        for id_, s in st.items():
            if s == 'done' and publish_states.get(id_) != 'done': stamps[id_] += 1
        publish_states = st
    elif body.startswith('START') or body.startswith('TERMINATED'):
        for id_ in list(open_ep): close(id_, ts, 'restart')

for id_ in list(open_ep): close(id_, last, 'eof')

print(f"log window: {first} .. {last}  ({n_lines} lines)")
for id_ in (0, 1, 2):
    eps = [e for e in episodes if e[0] == id_]
    if not eps:
        print(f"\n{names[id_]}: no working episodes"); continue
    tot = sum((e[2] - e[1]).total_seconds() for e in eps)
    by_src = {}
    for e in eps:
        key = '+'.join(sorted(e[3]))
        by_src.setdefault(key, []).append((e[2] - e[1]).total_seconds())
    print(f"\n{names[id_]}: {len(eps)} episodes, {tot/60:.1f} min working total, {stamps[id_]} stamps")
    for k, ds in sorted(by_src.items()):
        ds.sort()
        print(f"  source {k:8s}: n={len(ds):3d}  total {sum(ds)/60:6.1f} min  median {ds[len(ds)//2]:5.0f}s  max {ds[-1]:5.0f}s  <10s: {sum(1 for d in ds if d < 10)}")
    # the longest net-only episodes, with timestamps, to eyeball against what you were doing
    netonly = sorted([e for e in eps if e[3] == {'net'}], key=lambda e: e[1])
    if netonly:
        print(f"  net-only episodes (local time):")
        for e in netonly[-12:]:
            print(f"    {e[1].strftime('%m-%d %H:%M:%S')} +8h  {int((e[2]-e[1]).total_seconds()):4d}s")
