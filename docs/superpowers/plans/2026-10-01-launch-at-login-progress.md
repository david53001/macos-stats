# Launch-at-login switch — progress (2026-10-01)

> **Superseded by `docs/sparkle-updates/README.md` (2026-10-18).** On `feat/sparkle-updates` and
> later, `LoginItem.registerOnce()` is gone (MacStats never turns launch at login on by itself),
> the switch no longer sets `didRegisterLoginItem` (it is only read now) and any choice made with
> it marks the one-time "Open MacStats at login?" question as asked. The notes below describe the
> 2026-10-01 branch only.

Branch `feat/launch-at-login`, git worktree
`/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats/.claude/worktrees/launch-at-login`
(based on `feat/polish-perf`). Same feature is being added to JVoice and BetterScreenshot separately.

## Status: DONE (committed on `feat/launch-at-login`; not merged, not pushed, not installed)

- [x] `Sources/MacStatsApp/LoginItem.swift`: added `LoginItem.status` (= `SMAppService.mainApp.status`) and
      `LoginItem.setEnabled(_:) -> SMAppService.Status` (register/unregister, logs failures, returns the real
      status). `registerOnce()` unchanged.
- [x] `Sources/MacStatsApp/SettingsView.swift`: new `GeneralCard` above `AppearanceCard`.
- [x] `swift build` clean (no warnings), `./Scripts/test.sh` 114/114 pass.
- [ ] Not checked on-device: needs the bundled app (`./Scripts/bundle.sh`, which installs into
      `~/Applications`) — the bare `swift build` binary can't register, so its status is not `.enabled`.

## What the user sees

Overview footer → gear → Settings → **GENERAL** card (same card style as APPEARANCE): row
"Launch at login" (`.callout`) with a small native switch on the right; below it one `.caption` secondary line
"Open MacStats automatically when you log in." If macOS reports `.requiresApproval` (the user switched MacStats
off under System Settings → General → Login Items), that line becomes "Needs your approval in Login Items." with a
small bordered **Open** button that calls `SMAppService.openSystemSettingsLoginItems()`.

## Behaviour

- First launch: `registerOnce()` turns it on once, gated by UserDefaults `didRegisterLoginItem` (existing users
  keep their flag, so they're never re-enabled).
- The switch reads `SMAppService.mainApp.status` (source of truth) on appear and after every change; if
  register/unregister throws, the re-read status puts the switch back where the system really is.
- Flipping the switch also sets `didRegisterLoginItem = true`, so a user who turns it off before the first
  registration ever succeeded is not re-enabled on the next launch.
- No guided tour exists in MacStats, so no tour step was added.
