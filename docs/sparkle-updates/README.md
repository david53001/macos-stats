# MacStats: Sparkle auto-updates + the one-time "open at login?" prompt

Written 2026-10-18 for a fresh session with no context. MacStats is a SwiftPM menu-bar app
(no Xcode project; Command Line Tools only) in
`/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats`, GitHub
`david53001/macos-stats` (**public** repo). This work is on branch `feat/sparkle-updates`
(worktree `/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats/.claude/worktrees/sparkle-updates`),
based on `origin/main` (1.0.1). MacStats is the first of three sibling apps (MacStats, JVoice,
BetterScreenshot) to get this; the same approach is meant to be copied to the other two.

## Glossary

- **Sparkle** (https://sparkle-project.org): the standard open-source auto-update framework for
  Mac apps outside the App Store. Version used: **2.10.0**, exactly.
- **Appcast**: an RSS/XML file listing available versions. Each installed app downloads it from
  its `SUFeedURL` and compares the newest item's `sparkle:version` with its own `CFBundleVersion`.
- **EdDSA signature**: every update zip is signed with a private ed25519 key; the app carries the
  matching public key (`SUPublicEDKey`) and refuses any download whose signature doesn't match.
  This is what makes updates safe, independent of Apple code signing.
- **Code signing identity**: the certificate `codesign` signs the app with. macOS ties
  permissions (here: controlling Finder for the Trash card) to it.
- **`CFBundleVersion`** (build number, an integer here) vs **`CFBundleShortVersionString`**
  (the "1.2.0" users see). Sparkle compares the build number.
- **rpath**: a folder list baked into the executable where the dynamic loader looks for
  frameworks; `@executable_path/../Frameworks` = `MacStats.app/Contents/Frameworks`.
- **XPC service**: a helper process bundled inside an app/framework (`*.xpc`).
- **ATS** (App Transport Security): macOS's rule that apps only use HTTPS unless their
  Info.plist makes an exception. **TCC**: macOS's privacy-permission database (Automation,
  Screen Recording…), keyed to the app's code signature.
- **Hardened runtime**: an opt-in code-signing flag (`-o runtime`) that adds restrictions, incl.
  "library validation" (only load libraries signed by the same Team ID or Apple).

## What was added

### 1. Sparkle auto-updates

| Piece | Where |
|---|---|
| Dependency `.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")`, linked into `MacStatsApp` with rpath `@executable_path/../Frameworks` | `Package.swift`, `Package.resolved` |
| `SUFeedURL` = `https://github.com/david53001/macos-stats/releases/latest/download/appcast.xml`, `SUPublicEDKey` = `JrE6EncJErY++AZZXYrrwcNmcVzY/M2wgDWcCkaBf6U=`, `SUEnableAutomaticChecks` = YES (daily check, no "may we check?" dialog). Version **1.2.0**, build **4** | `Resources/Info.plist` |
| Updater: `SPUStandardUpdaterController`, started at launch; "gentle reminders" for a menu-bar app (a scheduled find opens Sparkle's window *behind* the user's windows, never stealing focus). So it isn't missed: one notification ("MacStats X is available", click → Sparkle's window comes forward), an accent **dot on the footer gear** and "Version X is available." + **Show Update…** in Settings, until the user looks at Sparkle's window | `Sources/MacStatsApp/Updates.swift` (started in `MacStatsMain.swift`), gear dot in `SettingsView.swift` (`SettingsButton`) |
| Settings → **UPDATES** card: "Check automatically" switch + **Check for Updates…** button (**Show Update…** while one waits) + current version (MacStats has no menu of its own, so this is where the menu item lives) | `Sources/MacStatsApp/SettingsView.swift` (`UpdatesCard`) |
| Bundle: copies `Sparkle.framework` into `Contents/Frameworks` (ditto, keeps symlinks) and removes its `XPCServices` (only sandboxed apps use them) and its `Headers`, `PrivateHeaders`, `Modules` (only for compiling against it). Deletes every absolute rpath except `/usr/lib/swift` (SwiftPM's build folder `…/PackageFrameworks` and the Command Line Tools' Swift folders), so only the embedded Sparkle can load and no path from the build Mac is left; fails if a new `@rpath` library other than Sparkle ever appears | `Scripts/bundle.sh` |
| Signing, inside-out, no `--deep`: `Autoupdate`, `Updater.app` (with hardened runtime, as shipped), the framework, then the app | `Scripts/sign-app.sh` |
| Stable self-signed identity **"MacStats Code Signing"** in its own keychain | `Scripts/setup-signing.sh` |
| One-command release: build, sign, zip, EdDSA-sign, appcast, print the `gh` command | `Scripts/package-release.sh` |
| Real end-to-end update test | `Scripts/sparkle-e2e-test.sh` |

**Not sandboxed** (checked: no entitlements file, no `com.apple.security.app-sandbox`). So Sparkle
installs through its bundled `Autoupdate` / `Updater.app`; the framework's XPC services
(`Installer.xpc`, `Downloader.xpc`) are only used by sandboxed apps (and only when
`SUEnableInstallerLauncherService` / `SUEnableDownloaderService` are set, which they aren't), and
Sparkle's docs say a non-sandboxed app may remove them, so `bundle.sh` does (two fewer signing
steps). The end-to-end test passes without them.

**Why a self-signed identity instead of ad-hoc (decision):** an ad-hoc signature is identified
by the code hash, which changes every build, so macOS forgot the Finder (Automation)
permission after every update (the old README warned about this). With auto-updates that would
re-ask after every release. A stable certificate gives every build the same designated
requirement (`identifier "com.macstats.MacStats" and certificate leaf = H"f0439366…"`), so the
permission survives updates, on every user's Mac. This matches JVoice ("JVoice Self-Signed")
and BetterScreenshot ("BetterScreenshot Code Signing"). Sparkle itself doesn't care: it trusts
updates by their EdDSA signature. One-time cost: users coming from 1.0.x (ad-hoc) are asked for
the Finder permission once more after installing 1.2.0.

**Why the app has no hardened runtime:** it never had one (not notarized). Hardened runtime
turns on library validation, which would refuse to load a `Sparkle.framework` signed by a
self-signed certificate (no Team ID). Sparkle's helper executables keep the hardened runtime
they ship with; they only load system libraries.

**Why 1.2.0 / build 4 (not 1.1.0 / 3):** 1.1.0 build 3 already exists on the unreleased
branches `fix/readings-accuracy` and `feat/stability-tour` (and is what's installed on this
Mac). Build numbers must only ever go up across everything that might ship, so this takes the
next minor version and the next build number. **Rule: every release raises `CFBundleVersion` by
one** (`package-release.sh` refuses a build number that isn't above the published appcast's).

### 2. "Open MacStats at login?" after 5 uses

Before: 1.0.x turned launch at login on silently at first launch (`LoginItem.registerOnce()`,
flag `didRegisterLoginItem`). That is **removed**. Now:

- A **use** = one open of the menu-bar panel that stayed on screen ≥ 1 s (a click-and-close
  glance doesn't count). Opens and closes follow the panel's **window**, because SwiftUI
  `onAppear`/`onDisappear` don't follow a `MenuBarExtra` window reliably (finding from
  `feat/stability-tour`, `docs/research/2026-10-06-probes/visibility/` there). On the branch that
  ships (`integrate/stability-tour-sparkle`, below) that is `AppModel.updateVisibility`: open =
  SwiftUI showed the content (`onAppear`) and the window is ordered in, read from the window's
  occlusion and became-key notifications (`PanelWindowObserver` in `RootView.swift`); it tells the
  tour first, then `LoginPrompt.panelOpened` / `panelClosed`. On `feat/sparkle-updates` alone,
  `PanelVisibilityObserver` (occlusion notifications, `isVisible`) calls
  `AppModel.panelVisibilityChanged`, which does the same minus the tour.
- **Every close returns the panel to the overview** (Settings and any breakdown are reset in
  `AppModel` at the close; `onDisappear` used to do it and didn't fire), and the card is shown
  **only over the overview** (`LoginCardGate`, MacStatsCore, tested): an open that lands anywhere
  else keeps it due for a later open. Round 3 found the card sitting over Settings after a close
  from there, where Esc went back under the card.
- After the **5th** use, the **next** open shows the question: a card **floating over the panel's
  own content**, covering the Memory and Network cards edge to edge (their bounds come from
  `.loginPromptAnchor()` in `OverviewView`; its text is centred vertically in that height; a
  centred fallback exists but the gate keeps the card to the overview), so no value is cut in half, over a dim (black 30 % light / 40 % dark, as the guided tour on
  `feat/stability-tour`): "Open MacStats at login?" / "Your stats stay one click away after a
  restart. You can change this any time in Settings." with **No Thanks** and **Open at Login**
  (accent-filled, the primary action). It is drawn *inside* the panel's fixed 320 × 404 pt frame
  (`RootView`: `.overlayPreferenceValue(LoginPromptAnchorKey.self) { LoginPromptOverlay(…) }`),
  so **the window never changes size**
  (round 1 found the old card-above-the-screens layout left the window 494 pt tall for good). It
  is decided while the panel is closed, so it's there from the open's first frame. It's inside the
  panel the user just opened, not a window or alert, so it can't take focus from typing.
- The dim takes clicks and hovers, so nothing under it opens by accident (Settings and the
  drill-ins can't be reached while the question is up, so the card and the Settings switch can
  never disagree); a click on the dim just puts the card away.
- **No Thanks** → card goes. **Open at Login** → `SMAppService.mainApp.register()`, then: enabled →
  "MacStats will open at login." for 1.6 s, then the card goes; `.requiresApproval` → "One more
  step / Allow MacStats in Login Items to finish." + **Done** / **Open Login Items**
  (`SMAppService.openSystemSettingsLoginItems()`); error → "Couldn't turn it on. / You can try again
  in Settings → Launch at login." + **Done**. If launch at login gets turned on elsewhere (System
  Settings), the card isn't shown again: the status is re-read whenever the panel closes (and
  opening System Settings closes it). Nothing watches it while the card is up.
- **Keyboard**, as in a macOS alert: Return = the accent button (Open at Login, Open Login Items;
  Done when it's the only button), Esc = No Thanks / Done. (Esc used to close the whole panel.)
  The screens under the card give up their own Esc while it is up (on the integration branch the
  Settings and breakdown back buttons use `.keyboardShortcut(loginPromptActive ? nil : .cancelAction)`),
  so Esc can only ever mean the card's button.
- **When it counts as asked** (`LaunchAtLoginPromptSession`, MacStatsCore, unit-tested): on an
  answer, or once the card has been on screen ≥ 1 s (then closing the panel or clicking the dim
  uses it up). A glance (click-and-close, or a click on the dim within 1 s) leaves it due for the
  next open, the same rule as "a glance isn't a use", but only twice: the **3rd** quick dismissal
  counts as asked (`launchAtLoginPromptQuickDismissals`), so someone who always clicks it away at
  once doesn't get a dimmed panel on every open.
- The Settings → GENERAL **Launch at login** switch (cherry-picked from `feat/launch-at-login`,
  commit cd57038) and the card observe the same `LaunchAtLogin` object, so they always agree.
- **Asked at most once ever** (answered, or seen for ≥ 1 s). Never asked if launch at login is
  already on. Any choice made with the Settings switch counts as answered.
- **Existing users**: if `didRegisterLoginItem` is set, 1.0.x already turned it on for them; they
  either still have it (nothing to do) or turned it off on purpose (respected): never asked, and
  their uses aren't counted.
- Design (MacStats design language, `docs/design-language/README.md`): continuous 8 pt corners
  (concentric with the panel) + the cards' 0.5 pt hairline, `.headline` title + `.callout`
  secondary line, `SubtleButtonStyle` buttons (`prominent: true` = accent fill, white text, the
  same style the tour's welcome card uses). Surface: exactly the tour's callout surface
  (`TourSurface` on `feat/stability-tour`): the system `.regularMaterial`, `windowBackgroundColor`
  at 92 % with Reduce Transparency, the hairline and the tour's one soft shadow (black 18 %,
  radius 12, y 4; the checklist's "one soft shadow per floating element": the two floating
  surfaces in the panel match). Not a plain card tint: the card floats over the (dimmed) cards, whose text
  would show through a 5–10 % tint. Not an opaque fill (round 1: principle 1 forbids it).

**UserDefaults keys** (domain `com.macstats.MacStats`):

| Key | Type | Meaning |
|---|---|---|
| `launchAtLoginPromptUses` | Int | Uses counted so far (stops at 5) |
| `launchAtLoginPromptAsked` | Bool | Shown once, or chosen in Settings: never ask again |
| `launchAtLoginPromptQuickDismissals` | Int | Times the card was put away within 1 s; the 3rd sets `…Asked` |
| `didRegisterLoginItem` | Bool | Legacy, **read only**: 1.0.x auto-enabled launch at login |

Code: rules + open/close cycle (pure, tested) `Sources/MacStatsCore/LaunchAtLoginPrompt.swift`
(`LaunchAtLoginPrompt`, `LaunchAtLoginPromptSession`); which opens may show the card and which
are uses (pure, tested) `Sources/MacStatsCore/LoginCardGate.swift`; tests
`Tests/MacStatsCoreTests/LaunchAtLoginPromptTests.swift`, `Tests/MacStatsCoreTests/LoginCardGateTests.swift`;
overlay + card + model `Sources/MacStatsApp/LoginPrompt.swift` (on `feat/sparkle-updates` alone also
`PanelVisibilityObserver`); open/close + the reset to the overview `AppModel` in
`Sources/MacStatsApp/MacStatsApp.swift`; `LaunchAtLogin` object `Sources/MacStatsApp/LoginItem.swift`;
placement `Sources/MacStatsApp/RootView.swift`; `SubtleButtonStyle(prominent:)` in `StatCard.swift`.

To see the card on a dev build without waiting for 5 uses (only on a Mac where you're happy to
change MacStats' own settings): `defaults write com.macstats.MacStats launchAtLoginPromptUses -int 5;
defaults delete com.macstats.MacStats launchAtLoginPromptAsked; defaults delete com.macstats.MacStats launchAtLoginPromptQuickDismissals; defaults delete com.macstats.MacStats didRegisterLoginItem`,
make sure launch at login is off, relaunch, open the panel.

**Live probe** (drives the real panel of a scratch copy with its own bundle id; re-run it after
any change to the card or the open/close wiring): `docs/research/2026-10-18-probes/login-prompt/`
(`README.md` there has the commands and the last results).

## Where the keys live (and their backups)

- **Sparkle EdDSA private key**: login Keychain, item "Private key for signing Sparkle updates",
  account `ed25519`. Sparkle's tools read it from there. Off-Keychain backup:
  `~/Backups/sparkle-signing-key/` (its `README.md` explains the files and how to restore with
  `~/Developer/Sparkle/2.10.0/bin/generate_keys -f …`). Same key for all three apps. **Never commit,
  print or upload the private key.** If it's lost, installed copies can't be updated any more.
- **Code signing identity "MacStats Code Signing"**: keychain
  `~/Library/Keychains/macstats-signing.keychain-db` (password `macstats-local`, in
  `Scripts/setup-signing.sh` on purpose: it only protects this local self-signed cert, same scheme
  as BetterScreenshot), on the user keychain search list. Backup copy:
  `~/Backups/macstats-code-signing/macstats-signing.keychain-db` (README there). Releases must be
  signed with this exact identity, or users are asked for the Finder permission again. To use it
  on another Mac: copy the keychain file to `~/Library/Keychains/` and add it to the search list
  (`security list-keychains -d user -s ~/Library/Keychains/macstats-signing.keychain-db $(security list-keychains -d user | tr -d '"')`).
  Don't run `setup-signing.sh` there first: it would create a *different* identity.
- Sparkle CLI tools: `/Users/davidghermansteinberg/Developer/Sparkle/2.10.0/bin`
  (`sign_update`, `generate_appcast`, `generate_keys`). The same tools also come with the SwiftPM
  artifact in `.build/artifacts/sparkle/Sparkle/bin`.

## How to cut a release (step by step)

All from the repo root on `main`, with this branch, **`feat/stability-tour`** (via
`integrate/stability-tour-sparkle`) **and `fix/battery-health`** merged (see STATUS / NEXT STEPS:
a release without them would take features away from the copy the owner runs; the script refuses):

```bash
cd /Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats
git switch main && git pull --ff-only origin main
# 1. Bump the version in Resources/Info.plist:
#    CFBundleShortVersionString (e.g. 1.2.0 -> 1.3.0) AND CFBundleVersion (+1, e.g. 4 -> 5).
# 2. Tests:
./Scripts/test.sh
# 3. Commit the bump and push it (package-release.sh refuses a dirty tree or HEAD != origin/main):
git commit -am "release: v1.3.0" && git push origin main
# 4. Release notes (Markdown, outside the repo so the tree stays clean); they become the GitHub
#    notes and Sparkle's update text. Then build + sign + zip + EdDSA-sign + appcast:
$EDITOR /tmp/macstats-notes.md
./Scripts/package-release.sh /tmp/macstats-notes.md
# 5. Run the gh command the script printed, which looks like (--target = the packaged commit):
gh release create v1.3.0 "<repo>/dist/MacStats.app.zip" "<repo>/dist/appcast.xml" \
    --repo david53001/macos-stats --target <HEAD sha> --latest --title "MacStats 1.3.0" --notes-file "<repo>/dist/release-notes.md"
```

Never use the `ALLOW_*` overrides below for a real release: if a guard refuses, fix the cause
(commit, push, merge) and run the script again. (`dist/` is in `.gitignore`, so the script's own
output doesn't make the tree dirty.)

`package-release.sh` outputs `dist/MacStats.app.zip` (the asset both `install.sh` and Sparkle
download), `dist/appcast.xml` (one item: this version, `sparkle:version` = build number, minimum
macOS, Markdown notes, enclosure URL `https://github.com/david53001/macos-stats/releases/download/vX.Y.Z/MacStats.app.zip`
with its EdDSA signature and length) and `dist/release-notes.md`. It fails if the
"MacStats Code Signing" identity is missing (`MACSTATS_REQUIRE_IDENTITY=1`), if the build number
isn't a whole number, or if it isn't above the currently published appcast's build. It publishes
nothing itself.

Guards (it refuses before building; the overrides are for dry runs only, never for a real release):

| Refuses when | Override |
|---|---|
| `git status --porcelain` is not empty (uncommitted or untracked files) | `ALLOW_DIRTY=1` |
| `HEAD` isn't `origin/main` (after `git fetch origin main`) | `ALLOW_NOT_MAIN=1` |
| `HEAD` doesn't contain a branch in the script's `MUST_CONTAIN` list (now `feat/stability-tour` and `fix/battery-health`, each checked as a local and an `origin/` branch where they exist; the tip at release time, so later commits on them count too) | `ALLOW_MISSING_BRANCHES=1` |
| a GitHub release with tag `vX.Y.Z` already exists (`gh release view`), or `gh` can't tell | none: bump the version |
| `CFBundleVersion` isn't a whole number, or isn't above the published appcast's | none |

`]]>` in the notes is escaped, so it can't end the appcast's CDATA block early.

### The `--latest` rule

Every installed copy reads `releases/latest/download/appcast.xml`: GitHub serves the
`appcast.xml` asset of whichever release is marked **Latest**. So:

- Every Mac release **must** be created with `--latest` and must attach `appcast.xml`.
- Any release that is *not* a Mac app release (e.g. a future Windows port, a beta, a source-only
  tag) **must** be created with `--latest=false`, or it becomes "Latest", the feed URL 404s and
  every Mac copy stops seeing updates (the curl installer would break too).
- Checked 2026-10-18: this repo has only Mac releases (v1.0.0, v1.0.1) and no
  `.github/workflows`, so nothing needed fixing here. JVoice / BetterScreenshot do have Windows
  builds: apply this rule there.

## How to re-run the end-to-end test

```bash
cd /Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats/.claude/worktrees/sparkle-updates   # or the repo root after merging
./Scripts/sparkle-e2e-test.sh              # temp dir, deleted afterwards
KEEP=1 ./Scripts/sparkle-e2e-test.sh /some/dir   # keep logs/builds for inspection
E2E_UI=1 ./Scripts/sparkle-e2e-test.sh     # the path real users take, through Sparkle's windows
```

It needs the "MacStats Code Signing" identity and the Sparkle key in the Keychain, takes about a
minute (one release build into its own scratch build folder) and briefly shows a second MacStats
icon in the menu bar. What it does: builds MacStats with `-DSPARKLE_E2E_TEST` (Sparkle steps
logged to stderr; a downloaded update installs immediately via Sparkle's
`immediateInstallationBlock` instead of on quit; no notification-permission request), makes an
OLD copy (build 100, "90.0") and a NEW copy (build 101, "90.1") with bundle id
`com.macstats.MacStats.sparkletest`, `SUFeedURL` = `http://127.0.0.1:8765/appcast.xml`,
`SUAutomaticallyUpdate` = YES, local-networking ATS exception, signed with the real identity;
zips NEW and signs it with the real EdDSA key; serves it with `python3 -m http.server` bound to
127.0.0.1 only; sets the test id's `SULastCheckTime` to 2000 so the check is due; runs OLD and
waits for the installed copy to become build 101 (GOOD), then repeats with an appcast whose
signature belongs to other bytes (BAD) and expects build 100 to stay. It never touches the real
app, the real bundle id's defaults or a running copy, quits everything it started and deletes
the test id's defaults, caches and Launch Services entries. Exit status 0 = both PASS.

Result 2026-10-18 (this Mac, macOS 26):

```
==> GOOD: signed update 100 -> 101
SPARKLE-E2E found 90.1 (build 101)
SPARKLE-E2E downloaded 101
SPARKLE-E2E ready to install 101; installing now
SPARKLE-E2E installing 101
installed copy: codesign --verify --deep --strict OK
Identifier=com.macstats.MacStats.sparkletest
Authority=MacStats Code Signing
running after relaunch: <pid> …/install/MacStats.app/Contents/MacOS/MacStats
==> BAD: zip whose EdDSA signature doesn't match
SPARKLE-E2E aborted: … Code=4005 "The update is improperly signed and could not be validated." …
  "EdDSA signature does not match. Data of the update being checked is different than data that has been signed …"
GOOD update installed (build 101): PASS
BAD signature refused (still build 100): PASS
```

**`E2E_UI=1` (UI mode)**: the OLD copy has no `SUAutomaticallyUpdate` and runs with
`SPARKLE_E2E_UI=1`, which turns on `Sources/MacStatsApp/SparkleE2EUI.swift` (compiled only into
the `-DSPARKLE_E2E_TEST` build; ported from JVoice / BetterScreenshot). The scheduled check must
set `pendingVersion` (= the gear dot and "Show Update…"), post the "MacStats X is available"
notification request and open Sparkle's update window: behind other windows without taking focus,
or in front when Sparkle chose "immediate focus" (it does right after launch or when the Mac is
idle, and then reports the user's attention at once). The driver then does what Show Update…
does, clicks **Install Update** and **Install and Relaunch** in Sparkle's own windows and the script
checks the installed copy is build 101, passes `codesign --verify --deep --strict` and is running
again. The test app's windows are made fully transparent (nothing shows on screen) and it hands
keyboard focus back to the app that was in front; snapshots of Sparkle's windows go to
`<work-dir>/ui/` (keep them with `KEEP=1`). The notification is requested but not shown: the test
build never asks for the notification permission.

### Manual checklist for the first real update (1.2.0 → 1.2.1)

The UI mode above covers Sparkle's windows, the dot/"Show Update…" state and Install and
Relaunch on a throwaway copy. What only a real release on the owner's Mac shows (owner, hard gate
for 1.2.1): the notification on screen and its click, the window really opening *behind* the
frontmost app (the UI mode usually gets "immediate focus"), the gear dot on real glass, and the
Finder permission surviving the update. On a Mac running the previous release:

1. Wait for (or force: `defaults write com.macstats.MacStats SULastCheckTime -date "2000-01-01 00:00:00 +0000"`,
   then relaunch MacStats) the scheduled check. Expect Sparkle's update window to open **without
   taking focus** (behind the frontmost app), and one notification "MacStats 1.2.1 is available".
2. Open the panel: the footer gear has a small accent dot. Settings → UPDATES says
   "Version 1.2.1 is available." on one line, with **Show Update…**.
3. Click the notification (or **Show Update…**): Sparkle's window comes to the front.
4. Click **Install Update**, then **Install and Relaunch**. MacStats relaunches as 1.2.1; the dot
   and the line are gone; the Trash card still works without a new Finder permission prompt.
5. Repeat once with **Remind Me Later**: the dot disappears when the window closes.

## STATUS / NEXT STEPS

- 2026-10-18: both features built and committed on `feat/sparkle-updates` (not merged, pushed,
  installed or released).
- **Review round 1** (independent reviewer, 5.5 / 10; report
  `docs/sparkle-updates/REVIEW-round1.md` + screenshots in `docs/sparkle-updates/review-round1/`,
  both left uncommitted in the worktree as the reviewer left them). Fixed in the commit after it:
  1. HIGH, panel stuck at 494 pt: the card now floats over the screens inside the fixed 404 pt
     frame (overlay + dim, centred); the window never resizes.
  2. A glance used up the only ask: now asked only on an answer or after ≥ 1 s on screen. The
     open/close cycle moved to MacStatsCore (`LaunchAtLoginPromptSession`) with 9 new tests.
  3. Opaque slab: replaced by the system material (see Design above). **Partly disagreed:** the
     reviewer suggested a plain card tint (`CardBackground()` or 8–10 %), which fitted the old card
     sitting on bare glass. Floating over the cards, a tint would show their text through the
     question, so it uses `.regularMaterial`, a translucent system material (principle 1 allows
     materials; the tour's callouts use the same).
  4. Found update easy to miss: gear dot + one notification + "Show Update…" (see the table above).
  5. Release would drop the installed 1.1.0 features: **not merged here** (that's the owner's
     call: `feat/stability-tour` is 600+ files and its own review loop is paused). Instead it's a
     hard, scripted step: `package-release.sh` refuses unless `HEAD` = `origin/main` *and*
     contains `feat/stability-tour` (see Guards). See NEXT STEPS 1.
  6. Update copy: "Version X is available." on one line (`lineLimit(1)`, `minimumScaleFactor(0.8)`);
     rendered with "1.12.10": one line, the card doesn't grow.
  7. Prompt copy/hierarchy: "No Thanks", accent-filled "Open at Login", the header stays at the
     top (card is centred over the dim), result text top-aligned in a card sized by its content.
  8. Card across Settings/drill-ins: impossible now (the dim blocks them). (Round 1 also claimed
     it goes away if launch at login is turned on elsewhere; round 2 found that never really
     fired, see below.)
  9. E2E covers only auto-install: manual checklist added above.
  10. `package-release.sh`: dirty tree / not origin/main / existing tag refused, `]]>` escaped.
  11. Docs: the two wrong statements are gone; `XPCServices/` is now removed from the bundle.
  12. Build-machine rpaths: all absolute rpaths except `/usr/lib/swift` are deleted (only Sparkle
      is an `@rpath` library; `bundle.sh` fails if that ever changes).
  13. Keychain password in the repo: **no change**, as the reviewer suggested (same scheme as
      BetterScreenshot; only protects a local self-signed cert).
- Verified after round 1 (2026-10-18): `./Scripts/test.sh` **135 tests pass** (126 + 9 session
  tests). `./Scripts/sparkle-e2e-test.sh`: GOOD PASS + BAD PASS (Code 4005/3002) with the
  XPC-less framework and stripped rpaths. **Live probe** (a scratch copy with a harness that
  clicks the real `MenuBarExtra` status button; own bundle id `com.macstats.MacStats.probe`,
  Finder call stubbed; deleted afterwards), 7 opens, dark and light: the panel frame is
  **320 × 404 on every open**, before, during and after the card; card due after the 5th use; a
  0.3 s glance → still due; a dim click 0.4 s in → card gone, still due; a 1.6 s look → asked,
  never shown again. Off-screen renders of all four card states and of Settings with a pending
  update, light and dark. Guards of `package-release.sh` each tried: dirty → refused; not main →
  refused; missing `feat/stability-tour` → refused; `v1.0.1` → "already exists".
- **Review round 2** (independent reviewer, **8.0 / 10**; report
  `docs/sparkle-updates/REVIEW-round2.md` + `docs/sparkle-updates/review-round2/`, uncommitted as
  the reviewer left them). Fixed in commit `7e055bd` (this branch) and on the integration branch
  (next section):
  1. MEDIUM, stability-tour not merged / merged UI unverified: **trial merge done on a separate
     branch `integrate/stability-tour-sparkle`** (worktree
     `/Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats/.claude/worktrees/integrate-tour-sparkle`),
     conflicts resolved, the card gated off while the tour / welcome / chip has the panel, tour
     opens not counted, dim drawn with the panel squircle, then tested and live-probed (below).
     **Not merged into `main` and not pushed: the owner approves that merge** (NEXT STEPS 1).
  2. MEDIUM, release steps vs guards: README and `CLAUDE.md` now say bump → `test.sh` → commit →
     `git push origin main` → `package-release.sh notes.md` → the printed `gh` command, which now
     has `--target <HEAD sha>`.
  3. Reflexive dismisser: the 3rd quick dismissal counts as asked
     (`launchAtLoginPromptQuickDismissals`, test `threeQuickDismissalsCountAsAsked`).
  4. Keyboard: Return = Open at Login / Open Login Items (Done when it's the only button), Esc = No
     Thanks / Done (`keyboardShortcut(.defaultAction / .cancelAction)`).
  5. Card cutting the Memory value: the card now covers the Memory and Network cards edge to edge
     (anchored to their bounds, content centred), centred only off the overview. Rendered: its
     edges sit exactly on the card boundaries (y 109–249 pt), light and dark, on both branches.
  6. Docs: the "goes if turned on elsewhere" claim is gone (and the `onChange` that practically
     never fired is removed: the status is re-read at every close); the 2026-10-01 progress note has a
     "Superseded" banner.
  7. Test count in `CLAUDE.md` updated (136 here, 394 on the integration branch).
  8. Shadow: kept, because it is exactly the tour's `TourSurface` shadow (black 18 %, radius 12,
     y 4); the surface now also copies the tour's Reduce Transparency fill, so both floating
     surfaces in the panel are identical (comment in `PromptSurface`).
  9. `bundle.sh` removes `Headers`, `PrivateHeaders`, `Modules` from the embedded framework; e2e
     re-run: GOOD PASS + BAD PASS.
- Verified after round 2 (2026-10-18), this branch: `./Scripts/test.sh` **136 tests pass**; release
  bundle (`MACSTATS_REQUIRE_IDENTITY=1`) passes `codesign --verify --deep --strict`, framework has
  only `Autoupdate`, `Resources`, `Sparkle`, `Updater.app`; `./Scripts/sparkle-e2e-test.sh` GOOD PASS +
  BAD PASS (Code 4005/3002). **Live probe** (scratch copy, bundle id `com.macstats.MacStats.r3probe`,
  Finder stubbed, feed dead, harness clicks the app's own `NSStatusBarButton`, synthesizes clicks
  and Esc into the panel window, deleted afterwards), light and dark, identical: frame **320 × 404
  on every open and close**; 5th use → due; dim click 0.35 s in → card gone, quick 1, still due; two
  0.3 s glances → quick 2 (due), quick 3 → **asked**; control click on CPU with no card → CPU
  breakdown; settled card + **Esc → asked, card gone, panel stays open**; 1.6 s look → asked.
  Return was not pressed live (it would register a real login item for the probe).

### Integration with `feat/stability-tour` (branch `integrate/stability-tour-sparkle`)

Made 2026-10-18 from local `feat/stability-tour` (9a29b2c, one docs commit ahead of
`origin/feat/stability-tour`) + this branch (merge commit `eea8832`). Nothing else touched: `main`,
`feat/stability-tour` and this branch are unchanged by it. Conflict resolutions:

| File | Resolution |
|---|---|
| `Resources/Info.plist` | 1.2.0 / build 4 (the installed copy is 1.1.0 / 3) |
| `StatCard.swift` | the tour's `SubtleButtonStyle` (`cornerRadius`, `height`, `prominent`) |
| `OverviewView.swift` | tour anchors and `.loginPromptAnchor()` on Memory + Network |
| `MacStatsApp.swift` | `tour` + `loginPrompt`; `LoginItem.registerOnce()` stays removed (the tour branch still called it); notification request skipped in the e2e build on both paths |
| `MacStatsMain.swift` | `RootView(…, tour:, loginPrompt:)`; the new-user auto-open is skipped in the e2e build |
| `RootView.swift` | the tour's version + the login overlay after `.tourHost` |
| `SettingsView.swift` | GENERAL (Launch at login + a **Take the Tour** row: the tour's HELP card folded in, because four cards + footer overflowed 404 pt and hid Quit), UPDATES, APPEARANCE; "Check for Updates…" uses `SubtleButtonStyle` like Default (squircle pass); gear: the tour's width + radius and the update dot |
| `LoginPrompt.swift` | driven by `AppModel.updateVisibility` (the tour's window-aware open/close) instead of its own observer, which is removed; dim = the panel's 16 pt continuous squircle (as `TourDimShape`; the window itself is rounded by `PanelShape`) |
| `LaunchAtLoginPrompt.swift` | `panelShown(at:blocked:)`, `panelHidden(at:countsAsUse:isEnabled:)` + 2 tests |

Rules on the merged code: the card never shows in an open the tour, its welcome card or the
"Take the Tour" chip has (decided at the open, after the tour; it stays due); an open the tour or
welcome took part in (at the open, or started during it) is not a use; a chip-only open is a use.

Verified there (2026-10-18): `./Scripts/test.sh` **394 tests pass**; release build signs and
verifies; `./Scripts/sparkle-e2e-test.sh` GOOD PASS + BAD PASS. Live probe (same harness), light and
dark, identical, **frame 320 × 404 on every one of ~50 opens/closes**: the whole round-2 sequence
above gives the same results (and a close now also leaves the breakdown, as the tour branch does);
chip open → no card, counted as a use (3 → 4); tour started mid-open → paused on close, not a use;
resumed tour open + Skip → no card mid-open, not a use (still 4); next real open → 5 → due; card +
dim click → quick 1; 1.5 s look → asked; Settings shows all three cards and Quit. New-user run
(`tourAudience=new`, 5 uses): welcome open → no card (twice), No Thanks, next open → card.
Renders: the card over Memory + Network with the squircle dim, the welcome card, the tour step 1,
the chip, Settings (light + dark).

- **Review round 3** (independent reviewer, **8.0 / 10**; report `docs/sparkle-updates/REVIEW-round3.md`
  + `docs/sparkle-updates/review-round3/`, uncommitted as the reviewer left them). Every item fixed
  on 2026-10-18, in commit `64ca563` (+ the docs commit after it) on this branch and merge `adfc5de`
  on `integrate/stability-tour-sparkle`:
  1. MEDIUM, the card could sit over Settings and Esc went back under it: (a) every real close now
     resets Settings and the breakdown in `AppModel` (`showingSettings` moved there from
     `RootView`'s `@State`; `onDisappear`, which used to reset it, doesn't fire for an ordered-out
     `MenuBarExtra` window), so the panel always reopens on the overview; (b) the card is shown only
     over the overview (`LoginCardGate`: an open on another screen is blocked and keeps it due);
     (c) on the integration branch the Settings and breakdown back buttons drop Esc while the card
     is up (`.keyboardShortcut(loginPromptActive ? nil : .cancelAction)`); (d) probe cases added
     (close from Settings / from a breakdown, reopen, Esc; and Settings forced under the card, Esc).
     The false "reset on close" comment is gone with the `@State`.
  2. LOW, untested glue: the open/close decisions (screen, tour active, chip, tour started during
     the open → blocked / a use) are now one pure struct, `Sources/MacStatsCore/LoginCardGate.swift`,
     with 6 tests (`LoginCardGateTests`, incl. gate + session sequences); `LoginPrompt` only passes
     them through. The live probe is committed: `docs/research/2026-10-18-probes/login-prompt/`
     (harness, scenarios for both branches, `probe.sh`, results). What stays app-side and is only
     covered by the probe: that `AppModel.updateVisibility` calls the tour before the card, and that
     the window notifications arrive (unit tests can't create a `MenuBarExtra` window).
  3. LOW, user-facing update path unverified: `E2E_UI=1 Scripts/sparkle-e2e-test.sh` now goes through
     Sparkle's real windows (see "How to re-run the end-to-end test"): scheduled find →
     `pendingVersion` (dot + "Show Update…") → notification request → update window → Show Update…
     → Install Update → Install and Relaunch → build 101, signature valid, relaunched. I used the
     JVoice / BetterScreenshot driver (in-process, finds Sparkle's buttons) instead of the suggested
     `CGWindowListCopyWindowInfo` check, because it also clicks through the install, which a window
     list can't. Return on the card is now probed with the login-item service stubbed (`probe.sh`
     patches the scratch copy and refuses to build if a real `SMAppService` call is left): enabled,
     needs approval (Return = Open Login Items) and error (Return = Done) all behave. **Not fixed,
     because they can't be on this Mac without a real release or the owner:** the notification on
     screen and its click (the test build never asks for the notification permission, by design:
     it must not leave a prompt behind), the window opening behind a frontmost app on an unlocked
     screen, Return on the real app (it would register a real login item), real Liquid Glass. They
     are the hard gate for 1.2.1 (manual checklist above) plus one owner check of the card.
  4. LOW, stale docs: §2 now describes the integration branch's wiring (`AppModel.updateVisibility`,
     `PanelWindowObserver`, `.overlayPreferenceValue`), with the sparkle-only observer named as such.
  5. NIT, help in GENERAL: the row is now "Guided tour" (`TourCatalog.helpRow`, integration branch;
     the button beside it still says Take the Tour). Rendered: `results-integration/light-T7-settings.png`
     in the probe folder.
  Also: `fix/battery-health` (the other session's battery fix; the copy in `~/Applications` was
  built from it) is now in `MUST_CONTAIN` (`Scripts/package-release.sh`), so a release refuses until
  it is merged.
- Verified after round 3 (2026-10-18; the screen was locked the whole time, the owner away):
  - `./Scripts/test.sh`: **144 tests pass** here, **400** on the integration branch.
  - Live probe (`docs/research/2026-10-18-probes/login-prompt/`, both branches, light and dark
    identical, frame 320 × 404 on every line): close from Settings / the CPU breakdown → reopen on
    the overview with the card → Esc = No Thanks (asked, card gone); Settings forced under the card
    → Esc answers the card and Settings stays; Return: enabled → confirmation gone by itself,
    needs approval → Return = Open Login Items (stub), error → Return = Done; integration also:
    chip open = no card but a use, tour opens not uses, resumed + skipped tour no card, welcome
    opens blocked then the card. Because the screen was locked, the harness posted the panel's
    occlusion notification itself after each toggle (macOS doesn't while locked) and clicks on
    the dim didn't register (the window can't become key); both were verified unlocked in rounds
    1-2 and that code is unchanged.
  - `./Scripts/sparkle-e2e-test.sh` on the integration branch: GOOD PASS + BAD PASS (Code
    4005/3002), exit 0. `E2E_UI=1`: all 11 checks PASS on both branches, exit 0 (log and
    snapshots: `docs/sparkle-updates/e2e-ui-2026-10-18/`; the snapshots are `cacheDisplay`
    renders of a transparent window, so Sparkle's text didn't draw; the log is the evidence). With
    the screen locked the window came up without focus (frontmost app `loginwindow`) although
    Sparkle asked for "immediate focus"; the "came up key" branch was not exercised.
  - `package-release.sh` on the integration branch: "HEAD is not origin/main"; with
    `ALLOW_NOT_MAIN=1`: "HEAD doesn't contain refs/heads/fix/battery-health". Nothing published.
  - Afterwards: no `sparkletest` / probe processes, defaults domains or caches left, port 8765
    free. `~/Applications`, `/Applications` and the `com.macstats.MacStats` defaults untouched.
- **Not tested** (needs the owner or a real release): the dim + material on real Liquid Glass
  (off-screen renders don't draw the glass), the real notification on screen and its click,
  Sparkle's window behind a frontmost app on an unlocked screen (checklist above), Return on the
  real app's card (it would register a login item on this Mac; probed with a stub instead).
- Note (2026-10-18 13:57): during this session `~/Applications/MacStats.app` was rebuilt from
  `.claude/worktrees/battery-health` (`fix/battery-health`, debug build, ad-hoc, 1.1.0 / 3) and
  relaunched by another session; none of this work's scripts write there (they all set
  `MACSTATS_APP`).

**NEXT STEPS (in this order):**

1. **Owner: approve the integration.** Review `integrate/stability-tour-sparkle` (worktree above;
   `git log feat/stability-tour..integrate/stability-tour-sparkle`, `git diff feat/stability-tour
   integrate/stability-tour-sparkle -- Sources`). If OK: merge it into `main`
   (`git switch main && git merge --no-ff integrate/stability-tour-sparkle`), then remove
   `feat/stability-tour` from `MUST_CONTAIN` in `Scripts/package-release.sh` only once it is on main
   for good. **Also merge `fix/battery-health`** (the battery fix another session is working on,
   worktree `.claude/worktrees/battery-health`; the installed copy was built from it) into main
   before 1.2.0: it is in `MUST_CONTAIN`, so `package-release.sh` refuses until it is in (remove it
   from the list once it's on main). If the tour branch gets more
   commits first, merge `feat/stability-tour` into the integration branch again (or redo the merge
   with the resolutions in the table above).
2. Push `main`, then cut 1.2.0 with the steps above. 1.0.1 users get 1.2.0 via the curl
   installer once; Sparkle takes over from there. Then run the manual checklist with 1.2.1, and
   check the card once on real glass (`defaults write … launchAtLoginPromptUses -int 5` etc., above).
3. Port the same template to JVoice and BetterScreenshot (their own repos; they already have
   stable identities; enforce `--latest=false` on their Windows releases). Both parts: Sparkle
   (embedding, inside-out signing, `package-release.sh` with guards, `sparkle-e2e-test.sh` incl.
   `E2E_UI=1`) **and** the one-time "open at login?" question after 5 uses (JVoice: 5 completed
   dictations; BetterScreenshot: 5 screenshots), with its rules in a pure, tested type like
   `LaunchAtLoginPrompt` + `LoginCardGate`, never a silent first-launch enable. (2026-10-18:
   JVoice's `feat/sparkle-updates` already has both; this review loop covered MacStats only.)
