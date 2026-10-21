#!/usr/bin/env python3
import json, sys
with open(sys.argv[1]) as f:
    elems = json.load(f)
for e in elems[:15]:
    r = e.get("role", "")
    l = e.get("label", "")
    v = e.get("value", "")
    print("{} {} = {}".format(r, l, v))
print("total: {} elements".format(len(elems)))
