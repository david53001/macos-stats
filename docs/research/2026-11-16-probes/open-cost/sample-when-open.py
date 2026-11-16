#!/usr/bin/env python3
"""Waits until MacStats' panel is on screen, skips 2 s, then runs `sample <pid> 12` into the given file.
Usage: sample-when-open.py <output.txt>. Passive: never opens the panel itself (see README.md)."""
import subprocess, time, sys
import Quartz
out = sys.argv[1]
pid = subprocess.run(["pgrep", "-x", "MacStats"], capture_output=True, text=True).stdout.split()[0]
def is_open():
    return any(w.get("kCGWindowOwnerName") == "MacStats" and w["kCGWindowBounds"]["Height"] > 200
               for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, 0))
t0 = time.time()
while not is_open():
    if time.time() - t0 > 1800: sys.exit("timeout")
    time.sleep(0.3)
time.sleep(2)   # skip the opening frame
print("panel open; sampling 12 s", flush=True)
subprocess.run(["sample", pid, "12", "1", "-mayDie", "-file", out])
print("done", flush=True)
