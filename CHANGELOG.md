# Changelog

What changed in each MacStats release, in plain language. The newest version is at the top. The
same text is used as the GitHub release notes and in MacStats' own update window.

## MacStats 1.3.0: steadier numbers, a short tour, more accurate readings

**Numbers and lists hold still.** The app lists under CPU, Memory and Battery no longer reshuffle
every second. Each app's number is averaged over a few seconds, an app only moves up when it is
clearly ahead, and nothing moves while your pointer is over the list. The cards change their
numbers only when the reading really changes. A new heavy load still shows within about two
seconds, and so does one that stops.

**See an app's processes.** Click an app in a list to see its processes, each with its own
numbers. Right-click an app or a process to quit it. Work that belongs to no app is listed as
**System** and **Other processes**, so the rows add up to the total at the top, and the work of
processes that already finished is counted from macOS's own per-app counters. Commands you run
in Terminal or VS Code now count toward that app.

**A short guided tour.** New users get a welcome card and a five-step tour of the panel. If you
already use MacStats, a "Take the Tour" button shows in the panel for a few opens. Replay it any
time with **?** in the panel's footer or Settings → General → Guided tour.

**Battery.**
- With a charge limit on, the time while charging counts to your limit ("Time to 85%"), and at
  the limit the status says "Charged to 85% limit" instead of "not charging".
- Hover the time left or time to full to see macOS's own estimate next to MacStats' one.
- The time left only learns from real use on battery, so a night asleep or time plugged in no
  longer throws it off.

**Memory** shows the same "Memory Used" as Activity Monitor, and the Memory screen shows what it is
made of: Apps, Kept by macOS and Compressed.

**Clearer wording.** Plain-language tooltips; memory says "OK", "running low" or "very low"; the
Trash says "Nothing in it", or "Needs permission" with an **Allow…** button.

**Also:** the panel's corners now match the rounded cards, and network speeds stay right on very
fast connections.

If you have 1.2.0, this update arrives on its own. From 1.0.x, re-run the install command in the
README once.

## MacStats 1.2.0: updates itself from now on

**MacStats updates itself.** It checks GitHub once a day and offers new versions in a small window
you can install from or put off. Every update is checked against MacStats' signing key before it's
installed. Settings → **Updates** has **Check automatically** and **Check for Updates…**.

**Launch at login is your choice.** MacStats no longer adds itself to your login items at first
launch. After a few uses it asks once whether to open at login. If you already have it, nothing
changes.

**Battery health matches macOS.** Health now shows the same "Maximum Capacity" as System Settings
(it could read a couple of percent low before).

**Trash size matches Finder** (Finder's units, and folders Finder is still measuring no longer
count as empty).

**Install this one by hand** (re-run the install one-liner from the README). Versions before 1.2.0
can't update themselves; from 1.2.0 on, updates arrive on their own. MacStats is now signed with a
stable certificate, so after this one-time install macOS may ask once more for Finder access (used
for the Trash size).

## MacStats 1.0.1

Accuracy fixes for the per-app breakdowns.

- **Memory** now shows each app's physical footprint, the same number as Activity Monitor. It used
  to include shared system memory, so apps looked bigger than they are.
- **CPU %** per app was about 40× too low on Apple Silicon Macs. Fixed; a process using a full core
  now reads 100%.
- Apps that just started no longer show 0% CPU for their first reading.

## MacStats 1.0.0

First public release.

- CPU, memory, network and battery in the menu bar, with per-app breakdowns.
- Battery shows charging, time until full, and a time-left estimate based on your average power
  use.
- Battery screen with power draw, health, cycle count, temperature and the apps using the most
  power.
