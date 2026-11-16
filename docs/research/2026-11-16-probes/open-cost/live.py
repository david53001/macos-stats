#!/usr/bin/env python3
"""Live open-panel cost of the running MacStats (README.md). Passive: polls every 0.5 s whether
MacStats' panel window is on screen (CGWindowList) and adds up MacStats' and WindowServer's CPU
time only while it is. Prints the totals after every close. Usage: live.py [open-seconds-wanted=30] [timeout-seconds=900]. Ends once
the panel has been open that long and is closed again (or at the timeout)."""
import subprocess, sys, time
import Quartz

want = float(sys.argv[1]) if len(sys.argv) > 1 else 30
timeout = float(sys.argv[2]) if len(sys.argv) > 2 else 900

def pid(name):
    out = subprocess.run(["pgrep", "-x", name], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None

def cpu(p):
    t = subprocess.run(["ps", "-o", "time=", "-p", str(p)], capture_output=True, text=True).stdout.strip()
    parts = [float(x) for x in t.replace("-", ":").split(":")]
    s = 0.0
    for x in parts: s = s * 60 + x
    return s

def panel_open():
    for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, 0):
        if w.get("kCGWindowOwnerName") == "MacStats" and w["kCGWindowBounds"]["Height"] > 200:
            return True
    return False

def report():
    pct = lambda c, t: 100 * c / t if t else float("nan")
    print(f"panel open   {open_t:6.1f} s: MacStats {pct(open_ms, open_t):5.2f} %  WindowServer {pct(open_ws, open_t):5.2f} %")
    print(f"panel closed {closed_t:6.1f} s: MacStats {pct(closed_ms, closed_t):5.2f} %  WindowServer {pct(closed_ws, closed_t):5.2f} %", flush=True)

ms, ws = pid("MacStats"), pid("WindowServer")
print(f"MacStats pid {ms}; waiting for {want:.0f} s with the panel open", flush=True)
open_t = closed_t = 0.0
open_ms = open_ws = closed_ms = closed_ws = 0.0
prev = (time.time(), cpu(ms), cpu(ws), panel_open())
start = prev[0]
while time.time() - start < timeout:
    time.sleep(0.5)
    now = (time.time(), cpu(ms), cpu(ws), panel_open())
    dt, dms, dws = now[0] - prev[0], now[1] - prev[1], now[2] - prev[2]
    if prev[3] and now[3]:
        open_t += dt; open_ms += dms; open_ws += dws
    elif not prev[3] and not now[3]:
        closed_t += dt; closed_ms += dms; closed_ws += dws
    if now[3] != prev[3]:
        print(("opened" if now[3] else "closed") + f" (open so far {open_t:.0f} s)", flush=True)
        if not now[3]: report()
    prev = now
    if open_t >= want and not now[3]:
        break
if open_t < want: report()
print("(% of one core; ps time has 0.01 s steps)")
