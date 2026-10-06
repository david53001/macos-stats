# Breakdown and card steadiness: the rules (design note)

MacStats is a native Swift macOS menu-bar system monitor (this repo). Clicking the CPU, Memory or Battery card
opens a **breakdown**: a ranked list of apps; clicking an app with several processes **expands** it into its
process rows. This note lists every rule that keeps the numbers and the list steady, the constant behind it and
the test that pins it, so a change can be judged without reading the history. Measurements and the reasons for
each value live in `docs/research/2026-10-06-stability-diagnosis.md` and `docs/research/2026-10-06-probes/*/README.md`.

**Terms.** A **scan** is one per-process read for an open breakdown (every 2 s). The **window** is the span a
row's number is averaged over. A row's **printed value** is the number on screen (held); its **exact value**
drives the bar. **Frozen** means the order isn't changed by a scan. **pp** = percentage points of the whole Mac.
Tests are in `Tests/MacStatsCoreTests/`; run them with `./Scripts/test.sh` (or `--filter <Suite>`).

## 1. Where the numbers come from (`BreakdownScanner`, `Sources/MacStatsCore/ProcessScan.swift`)

| # | Rule | Constant (`RefreshScheduler.swift`) | Test |
|---|---|---|---|
| 1 | Scans every 2 s, only while a breakdown is shown | `breakdownScanInterval` = 2 s | `RefreshSchedulerTests` |
| 2 | CPU rows and the CPU header average the last 8 s; Battery (energy) rows 16 s; Memory is instantaneous | `trailingWindowSeconds` = 8, `energyWindowSeconds` = 16 | `BreakdownWindowTests` |
| 3 | **Fast attack and release:** when one app used ≥ ¾ of a core more *or less* over the latest interval than over the rest of the window, the window restarts from that interval, so a load that starts or ends shows within one scan | `breakdownFastAttackCores` = 0.75 | `aNewLoadRestartsTheWindow`, `aLoadThatEndsRestartsTheWindow` |
| 4 | Work of processes that exited mid-window goes to their app's "Finished processes" row (else System) | — | `exitMidWindowGoesToTheAppsExitedRow` |

## 2. What a row prints (`BreakdownDisplay`, `Sources/MacStatsCore/BreakdownDisplay.swift`)

| # | Rule | Constant | Test |
|---|---|---|---|
| 5 | A row's printed value changes only when the reading is ≥ max(0.75 × the printed step, min(10 % of it, 2 pp)) away (Memory 3 %, no cap; Battery 10 %, 0.2 W), confirmed on two scans unless it moved twice that | `RowHold` (`StableRanking.swift`), `HeldReading` (`DisplayHold.swift`) | `heldTextValuesStayWithinTheirBound`, `rowChangesNeedTwoScansUnlessBig` |
| 6 | The CPU header starts at the CPU card's value and is held with a 0.75 pp band | `RowHold.cpu.band` | `theHeaderStartsFromTheCardValue`, `headerIsHeldLikeTheCard` |
| 7 | Bars use a sticky 1-2-5 scale above the top row (CPU, Battery) | `stickyUpperBound` | `cpuBarsFollowTheTopRow`, `energyScaleIsSticky` |
| 8 | "Finished processes" shows only while it prints more than 0 (or the list is frozen) | — | `exitedRowShowsOnlyWhileItHasSomethingToShow` |

## 3. Order (`stableRanking` in `StableRanking.swift`, `ListRanking` in `BreakdownDisplay.swift`)

Rows are ranked by their **printed** values, so the order agrees with the numbers on screen.

| # | Rule | Constant | Test |
|---|---|---|---|
| 9 | **Hysteresis:** a row passes the one above only with a lead of both 15 % and 0.15 pp (Battery 15 % / 0.015 W, Memory 5 % / 20 MB), or at once with a **jump** (> 1.5× and > 1 pp / 0.05 W / 200 MB) | `RankHysteresis` | `StableRankingTests` |
| 10 | **Inversion timeout:** a row printed higher than the row above on one scan passes it on the next allowed scan, margins or not | — | `aSmallInversionLastsOneScan`, `aPromotedKeyPassesWithinTheMargin` |
| 11 | …except process rows printed under 0.5 % (0.05 W), and "Finished processes": they pass only by the margins (tiny values crossing are noise) | `RankHysteresis.promotionFloor` | `tinyProcessRowsDontSwapByTheInversionTimeout` |
| 12 | **Reorder dwell:** apart from a jump, the app list reorders at most once per 5 s, each app's process rows once per 10 s | `breakdownReorderDwell` = 5, `breakdownProcessReorderDwell` = 10 | `theListReordersAtMostOncePerDwell`, `processRowsReorderAtMostOncePerTheirDwell` |
| 13 | A process new to a listed app joins below the app's known processes for one scan (most are short-lived) | — | `aNewProcessJoinsBelowItsAppsKnownOnesForOneScan` |
| 14 | Memory's group rows (Other processes) stay after every app | `groupsLast` | `groupsStayLastForMemory`, `memoryGroupRowsStayLast` |

## 4. The freeze (nothing moves under the pointer)

| # | Rule | Constant | Test |
|---|---|---|---|
| 15 | The order freezes while the pointer is over the list **once it has moved** (or scrolled or clicked there) since the list appeared; a pointer still resting from the card click doesn't freeze it | — | `aPointerStillRestingFromTheClickDoesNotFreeze`, `pointerProbeFreezesWithoutAHoverEvent` |
| 16 | **Partial freeze:** with the pointer on a known app's rows, only the apps down to and including that app keep their places; the apps below still re-rank (never past it). Unknown row (between rows, after a scroll until the next hover), an open context menu or the unfreeze delay freeze everything | `BreakdownFreeze` | `aPointerOnAnAppFreezesOnlyDownToIt`, `frozenKeepsTheShownRowsAsAPrefix` (property test, all metrics) |
| 17 | A context menu freezes everything; a menu opened without moving counts as pointing | — | `menuFreezeWorksTheSameWay`, `aMenuOpenedWithoutMovingCountsAsPointing` |
| 18 | The freeze ends at the first scan ≥ 1 s after the pointer leaves (or the menu closes); checked against scan times, no timer | `breakdownUnfreezeDelay` = 1 s | `unfreezeHappensAtTheFirstScanASecondAfterThePointerLeaves` |
| 19 | While frozen: ended apps and processes stay as dimmed "Ended" placeholders (an ended expanded app keeps its processes and a disabled "N more…"), and an app gains no new process rows | — | `freezeHoldsOrderButUpdatesValuesAppendsAndRemoves`, `anEndedAppKeepsItsProcessesWhileFrozen`, `endedProcessesKeepTheirPlaceWhileFrozen`, `aFrozenAppGainsNoRows`, `anEndedAppKeepsItsMoreRowDisabled` |

The view side (`Sources/MacStatsApp/BreakdownView.swift`): `PointerProbe` reads AppKit's pointer location once a
scan and keeps a local scroll/click monitor only while a breakdown is shown; `RowHover` records which app's rows
the pointer is over from the rows' hover events.

## 5. The overview cards (`MetricsStore.updateCards`)

| # | Rule | Constant | Test |
|---|---|---|---|
| 20 | Rates (CPU %, network) are a 2 s trailing average at the 0.5 s open cadence | `rateWindowSeconds` = 2 | `RateWindowTests` |
| 21 | CPU card: held within 1.25 pp; a 3 pp move shows at once; otherwise its text changes at most every 2 s | `cardDwellSeconds` = 2 | `cardValuesHoldThenPassARealMove`, `cardTextDwellsUnlessTheReadingJumps` |
| 22 | Network: held within 2 printed steps or 15 % (↑ 20 %), same dwell; doubling/halving by ≥ 10 KB/s shows at once | `heldRate` | `rateHoldsSmallWobble`, `rateUnitSwitchIsHeld` |
| 23 | Memory card and Memory breakdown header/parts held as one sample (0.1 GB; a pressure change passes at once) | `heldMemory` | `memoryIsHeldAsOneSample`, `memoryPressureChangePassesAtOnce` |

## Considered and not done
- **Merging the dwell (12) and the inversion timeout (10) into one "a row must lead for N s" rule.** It would
  change every measured trade-off at once (reorders per minute against how long an inversion can last); the two
  rules are each one small, tested function in `ListRanking.rank`, so they stay separate until a replay shows a
  merged rule doing better.
- **Unfreezing a row that leads by a lot while the pointer rests on the list.** It would move rows under the
  pointer; the partial freeze (16) lets rows below the pointer re-sort instead.

## How to judge a change
Replay a live recording through the real display code and compare the measures (order changes per minute,
inversion scans, child-row reorders, burst rise and fall): `docs/research/2026-10-06-probes/r5-fixes/README.md`.
