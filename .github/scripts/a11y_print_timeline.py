#!/usr/bin/env python3
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
tl = data.get("timeline", data) if isinstance(data, dict) else data
for e in tl:
    ts = e.get("timestamp", 0)
    desc = e.get("description", "")
    action = e.get("action", "")
    print("{:.1f}s {} ({})".format(ts, desc, action))
