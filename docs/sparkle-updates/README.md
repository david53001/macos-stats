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
| Updater: `SPUStandardUpdaterController`, started at launch; "gentle reminders" for a menu-bar app (a scheduled find is shown behind the user's windows, never stealing focus, and Settings says it's waiting) | `Sources/MacStatsApp/Updates.swift`, started in `MacStatsMain.swift` |
| Settings → **UPDATES** card: "Check automatically" switch + **Check for Updates…** button + current version (MacStats has no menu of its own, so this is where the menu item lives) | `Sources/MacStatsApp/SettingsView.swift` (`UpdatesCard`) |
| Bundle: copies `Sparkle.framework` into `Contents/Frameworks` (ditto, keeps symlinks), deletes SwiftPM's rpath to its own build folder so only the embedded copy can load | `Scripts/bundle.sh` |
| Signing, inside-out, no `--deep`: `Installer.xpc`, `Downloader.xpc` (keeps its entitlements), `Autoupdate`, `Updater.app` (all with hardened runtime, as shipped), the framework, then the app | `Scripts/sign-app.sh` |
| Stable self-signed identity **"MacStats Code Signing"** in its own keychain | `Scripts/setup-signing.sh` |
| One-command release: build, sign, zip, EdDSA-sign, appcast, print the `gh` command | `Scripts/package-release.sh` |
| Real end-to-end update test | `Scripts/sparkle-e2e-test.sh` |

**Not sandboxed** (checked: no entitlements file, no `com.apple.security.app-sandbox`). So Sparkle
installs through its bundled `Autoupdate` / `Updater.app`; the framework's XPC services
(`Installer.xpc`, `Downloader.xpc`) are only used by sandboxed apps. They are shipped unchanged
and signed, but `SUEnableInstallerLauncherService` / `SUEnableDownloaderService` are not set,
so they stay unused.

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
- After the **5th** use, the **next** open shows a card at the top of the panel: "Open MacStats
  at login?" with **Not Now** / **Open at Login**. It is decided while the panel is closed, so
  the panel opens at its final size; it's a card inside the panel the user just opened, not a
  window or alert, so it can't take focus from typing or cover anything. After an answer the card
  keeps its size and shows the result until the panel closes; from the next open it's gone.
- **Open at Login** → `SMAppService.mainApp.register()`. Result shown: enabled; `.requiresApproval`
  → "One more step" + **Open Login Items** (`SMAppService.openSystemSettingsLoginItems()`); error →
  "Couldn't turn it on. You can try again in Settings → Launch at login."
- The Settings → GENERAL **Launch at login** switch (cherry-picked from `feat/launch-at-login`,
  commit cd57038) and the card observe the same `LaunchAtLogin` object, so they always agree.
- **Asked at most once ever** (shown = asked, answered or not). Never asked if launch at login is
  already on. Any choice made with the Settings switch counts as answered.
- **Existing users**: if `didRegisterLoginItem` is set, 1.0.x already turned it on for them; they
  either still have it (nothing to do) or turned it off on purpose (respected): never asked, and
  their uses aren't counted.
- Design (MacStats design language, `docs/design-language/README.md`): same continuous 8 pt
  corners + hairline as the cards, `SubtleButtonStyle` buttons, `.callout` semibold title +
  `.caption` line, all `.primary` text on a 90 %-opaque `windowBackgroundColor` layer ("slightly
  transparent"). Worst-case text contrast, computed from the system colours with the backdrop
  replaced by pure white/black: dark mode 8.1:1 (white behind) / 11.2:1 (black behind), light
  mode 13.7:1 / 11.5:1, so ≥ 4.5:1 at every Opacity setting.

**UserDefaults keys** (domain `com.macstats.MacStats`):

| Key | Type | Meaning |
|---|---|---|
| `launchAtLoginPromptUses` | Int | Uses counted so far (stops at 5) |
| `launchAtLoginPromptAsked` | Bool | Shown once, or chosen in Settings: never ask again |
| `didRegisterLoginItem` | Bool | Legacy, **read only**: 1.0.x auto-enabled launch at login |

Code: rules (pure, tested) `Sources/MacStatsCore/LaunchAtLoginPrompt.swift`; tests
`Tests/MacStatsCoreTests/LaunchAtLoginPromptTests.swift`; card + model + window observer
`Sources/MacStatsApp/LoginPrompt.swift`; `LaunchAtLogin` object `Sources/MacStatsApp/LoginItem.swift`;
layout `Sources/MacStatsApp/RootView.swift`.

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

All from the repo root on `main` with this branch merged:

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

## STATUS / NEXT STEPS

- 2026-10-18: both features built and committed on `feat/sparkle-updates` (not merged, pushed,
  installed or released). Verified: `./Scripts/test.sh` (126 tests pass, incl. 9 new
  `LaunchAtLoginPromptTests`), `./Scripts/package-release.sh` (signed bundle, zip, appcast,
  printed `gh` command), `./Scripts/sparkle-e2e-test.sh` (GOOD + BAD pass), worst-case prompt
  contrast computed, prompt card + Settings rendered off-screen in light/dark, and the
  use-counting state machine driven through 8 open/close cycles of a real window (glance not
  counted; card due after the 5th use; marked asked on the 6th open; gone after it).
- **Not tested** (needs clicking the real menu bar / the owner): the card inside the real
  `MenuBarExtra` panel (panel growing by the card's height on that one open), the Settings
  "Check for Updates…" button and Sparkle's own update window, `.requiresApproval` on screen,
  and an update from a real GitHub release (the first one can only be tested after 1.2.0 *and* a
  later release are published).
- Next (owner decisions): merge to `main` (this branch is based on `origin/main`, not on the
  unmerged `feat/stability-tour`; merging that later will conflict in `RootView.swift`,
  `LoginItem.swift`, `SettingsView.swift`, `Info.plist`, `bundle.sh` — keep both sides' intent and
  a build number above 4), push, then cut 1.2.0 with the steps above. 1.0.1 users get 1.2.0 via
  the curl installer once; Sparkle takes over from there.
- Then port the same template to JVoice and BetterScreenshot (their own repos; they already have
  stable identities; enforce `--latest=false` on their Windows releases).
