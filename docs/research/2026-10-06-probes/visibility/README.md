# Panel visibility probe (2026-10-06)

**Question.** Review round 1 found the installed MacStats (v1.1.0) at about 28 % of one core for hours with
its 320×404 panel window *not on screen*: the 0.5 s "panel open" tick and the sparkline slides kept running.
Open/closed was decided only by SwiftUI `onAppear` / `onDisappear` on the `MenuBarExtra` content. Does
`onDisappear` fire when a hosting window is taken off screen, and do the window notifications report it?

**Run** (off-screen: a borderless window at desktop level + 1, ordered back, never activated):

```bash
cd /Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swiftc -O docs/research/2026-10-06-probes/visibility/main.swift -o "$TMPDIR/visprobe"
("$TMPDIR/visprobe" & PID=$!; (sleep 30; kill $PID) & wait $PID)
```

**Result** (this Mac, macOS 26):

```
918.89 onAppear                       <- fires when the content is installed, before the window shows
919.05 == orderBack
919.08 notify ChangeOcclusionState isVisible=true  occl.visible=true  => onScreen=true
920.41 == orderOut
920.42 notify ChangeOcclusionState isVisible=false occl.visible=false => onScreen=false
921.97 == orderBack again
921.99 notify ChangeOcclusionState isVisible=true  occl.visible=true  => onScreen=true
923.55 == orderOut again
923.56 notify ChangeOcclusionState isVisible=false occl.visible=false => onScreen=false
925.13 == close                        <- onDisappear never fired, not even on close
```

So `onDisappear` is not a reliable "panel hidden" signal, while the window's occlusion notification fires
within ~20 ms of every show and hide. **Fix** (`AppModel.setPanelAppeared` / `panelWindowChanged`,
`RootView.PanelWindowObserver`): the panel is "open" only while SwiftUI shows its content **and** its window
is on screen (`isVisible && occlusionState.contains(.visible)`); the 0.5 s timer also re-checks the window
before each tick. `onAppear` still counts as on screen, so the first tick runs before the first frame as before.
