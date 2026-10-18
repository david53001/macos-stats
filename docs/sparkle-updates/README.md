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
| Bundle: copies `Sparkle.framework` into `Contents/Frameworks` (ditto, keeps symlinks) and removes its `XPCServices` (only sandboxed apps use them). Deletes every absolute rpath except `/usr/lib/swift` (SwiftPM's build folder `…/PackageFrameworks` and the Command Line Tools' Swift folders), so only the embedded Sparkle can load and no path from the build Mac is left; fails if a new `@rpath` library other than Sparkle ever appears | `Scripts/bundle.sh` |
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
  glance doesn't count). Opens are tracked from the panel window's occlusion notifications
  (`isVisible`), because SwiftUI `onAppear`/`onDisappear` don't follow a `MenuBarExtra` window
  reliably (finding from `feat/stability-tour`, `docs/research/2026-10-06-probes/visibility/` there).
- After the **5th** use, the **next** open shows the question: a card **floating over the panel's
  own content**, centred, over a dim (black 30 % light / 40 % dark, as the guided tour on
  `feat/stability-tour`): "Open MacStats at login?" / "Your stats stay one click away after a
  restart. You can change this any time in Settings." with **No Thanks** and **Open at Login**
  (accent-filled, the primary action). It is drawn *inside* the panel's fixed 320 × 404 pt frame
  (`RootView`: `screens.overlay { LoginPromptOverlay }`), so **the window never changes size**
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
  Settings) while the question is up, the card goes.
- **When it counts as asked** (`LaunchAtLoginPromptSession`, MacStatsCore, unit-tested): on an
  answer, or once the card has been on screen ≥ 1 s (then closing the panel or clicking the dim
  uses it up). A glance (click-and-close, or a click on the dim within 1 s) leaves it due for the
  next open, the same rule as "a glance isn't a use".
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
  same style the tour's welcome card uses). Surface: the system `.regularMaterial` (translucent;
  macOS makes it solid by itself with Reduce Transparency) + one soft shadow, the same surface as
  the tour's callouts. Not a plain card tint: the card floats over the (dimmed) cards, whose text
  would show through a 5–10 % tint. Not an opaque fill (round 1: principle 1 forbids it).

**UserDefaults keys** (domain `com.macstats.MacStats`):

| Key | Type | Meaning |
|---|---|---|
| `launchAtLoginPromptUses` | Int | Uses counted so far (stops at 5) |
| `launchAtLoginPromptAsked` | Bool | Shown once, or chosen in Settings: never ask again |
| `didRegisterLoginItem` | Bool | Legacy, **read only**: 1.0.x auto-enabled launch at login |

Code: rules + open/close cycle (pure, tested) `Sources/MacStatsCore/LaunchAtLoginPrompt.swift`
(`LaunchAtLoginPrompt`, `LaunchAtLoginPromptSession`); tests
`Tests/MacStatsCoreTests/LaunchAtLoginPromptTests.swift`; overlay + card + model + window observer
`Sources/MacStatsApp/LoginPrompt.swift`; `LaunchAtLogin` object `Sources/MacStatsApp/LoginItem.swift`;
placement `Sources/MacStatsApp/RootView.swift`; `SubtleButtonStyle(prominent:)` in `StatCard.swift`.

To see the card on a dev build without waiting for 5 uses (only on a Mac where you're happy to
change MacStats' own settings): `defaults write com.macstats.MacStats launchAtLoginPromptUses -int 5;
defaults delete com.macstats.MacStats launchAtLoginPromptAsked; defaults delete com.macstats.MacStats didRegisterLoginItem`,
make sure launch at login is off, relaunch, open the panel.

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

All from the repo root on `main`, with this branch **and `feat/stability-tour`** merged (see
STATUS / NEXT STEPS: a release without the stability-tour work would take features away from the
copy the owner runs):

```bash
cd /Users/davidghermansteinberg/Desktop/Home/Projects/Code/MacStats
# 1. Bump the version in Resources/Info.plist:
#    CFBundleShortVersionString (e.g. 1.2.0 -> 1.3.0) AND CFBundleVersion (+1, e.g. 4 -> 5).
# 2. Write release notes (Markdown); they become the GitHub notes and Sparkle's update text:
$EDITOR /tmp/macstats-notes.md
# 3. Tests, then build + sign + zip + EdDSA-sign + appcast:
./Scripts/test.sh
./Scripts/package-release.sh /tmp/macstats-notes.md
# 4. Commit the bump, push main, then run the gh command the script printed, which looks like:
gh release create v1.3.0 "<repo>/dist/MacStats.app.zip" "<repo>/dist/appcast.xml" \
    --repo david53001/macos-stats --latest --title "MacStats 1.3.0" --notes-file "<repo>/dist/release-notes.md"
```

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
| `HEAD` doesn't contain a branch in the script's `MUST_CONTAIN` list (now `feat/stability-tour`, checked as a local and an `origin/` branch where they exist) | `ALLOW_MISSING_BRANCHES=1` |
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

### Manual checklist for the first real update (1.2.0 → 1.2.1)

The end-to-end test sets `SUAutomaticallyUpdate` and installs at once; real users get Sparkle's
window instead. The first time a real later release exists, check on a Mac running the previous
release (owner):

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
  8. Card across Settings/drill-ins: impossible now (the dim blocks them); also goes away if
     launch at login gets turned on elsewhere.
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
- **Not tested** (needs the owner or a real release): the dim + material on real Liquid Glass
  (off-screen renders don't draw the glass), the real notification and its click, Sparkle's own
  window and "Install and Relaunch" (checklist above), `.requiresApproval` on screen.

**NEXT STEPS (in this order):**

1. **Hard step before any release:** get `feat/stability-tour` (which contains
   `fix/readings-accuracy`) and this branch into `main`. The installed copy is 1.1.0 build 3
   from `feat/stability-tour` (readings accuracy, stability fixes, squircle panel, guided tour,
   373 tests); 1.2.0 from this branch alone would remove all of that from every copy Sparkle
   updates. Expected conflicts: `RootView.swift`, `LoginItem.swift`, `SettingsView.swift`,
   `StatCard.swift` (`SubtleButtonStyle`: take the tour's version, it already has `prominent`),
   `Info.plist` (keep 1.2.0 / build ≥ 4), `bundle.sh`. After merging: put `LoginPromptOverlay`
   under the tour's host so the two never show at once (don't show the login card while the
   tour, its welcome card or the "Take the Tour" chip is up; count a tour open as a use only
   after the tour ended); draw the dim with the tour's panel squircle (`PanelShape`, 16 pt)
   instead of a plain rectangle; re-run the live probe there (a harness like the one described
   above: `performClick` on the app's own `NSStatusBarButton`, log the `MenuBarExtraWindow`
   frame on each open).
2. Push `main`, then cut 1.2.0 with the steps above. 1.0.1 users get 1.2.0 via the curl
   installer once; Sparkle takes over from there. Then run the manual checklist with 1.2.1.
3. Port the same template to JVoice and BetterScreenshot (their own repos; they already have
   stable identities; enforce `--latest=false` on their Windows releases).
