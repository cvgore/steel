# Watch workout navigation (STEEL-10)

The phone-created session is presented only after the durable Watch replica reports agreement. HealthKit preparation alone shows a waiting state. A missing session shows the existing iPhone start instruction. No Watch catalog or start action is added.

The four horizontal pages are Finish, Workout, Measurements and Now Playing. Measurements reuses `WorkoutSessionView`; Finish reuses `OptionsView`. Their integration behavior is unchanged. Shared finalization belongs to STEEL-13.

Workout owns a native `NavigationStack`: exercise list → current set → exercise sets → completed set details. The final destination owns a correction draft for the STEEL-12 editor. Current-set input, Crown behavior, saving and progression belong to STEEL-11; correction input/save and completion/record indicators belong to STEEL-12. These destinations currently display values without offering a save action.

`WatchWorkoutNavigation` owns stable exercise/set identities, the working-set selection, current drafts, correction draft, path and selected page. It is encoded in Watch-local `AppStorage`, outside the synchronized replica. Paging preserves this state; native Back discards only the correction draft when leaving its destination. Reselecting an exercise does not reload an existing draft. `selectWorkingSet` lets the later progression implementation update content without pushing a route.

Reopening restores the same session context. A new or terminal session resets it. Snapshot updates preserve navigation and drafts, including a correction whose set becomes incomplete on the phone; deleted identities trim invalid destinations and drafts. If an open exercise loses its working set, select its first unfinished set or last completed set without pushing a route or overwriting an existing draft. Adding the first set to an open empty exercise initializes its selection the same way. No phone selection or navigation is changed.

## Validation

`WatchWorkoutNavigationTests` covers agreement gating, paging/reopen, Back discard, working-set changes without extra navigation, remote result updates, deleted identities, empty/completed exercises and session reset. Run it using the simulator workflow in [testing.md](testing.md), selecting `IronTests/WatchWorkoutNavigationTests`.

Watch Debug/Release builds validate view compilation. Small-Watch and larger-text swipe/Back/Crown behavior and paired-device joining/resume still require device testing. The STEEL-11/12 input controls are not available for Crown testing in this task.

## Recorded simulator checks — November 2, 2026

- Xcode 27.0 (27A266a), iOS/watchOS 27 simulator SDKs.
- `IronTests/WatchWorkoutNavigationTests`: 8 passed, 0 failed, 0 skipped on a dedicated iPhone 17 simulator. Result bundle: `/tmp/steel10-navigation-final.xcresult`.
- `WatchIron` Debug and Release simulator builds passed using pinned package versions and `CODE_SIGN_IDENTITY=-`. Logs: `/tmp/steel10-watch-Debug-final.log` and `/tmp/steel10-watch-Release-final.log`.
- Localization/catalog validation and `git diff --check` passed.
- The first parallel Release attempt failed because Xcode's build database was locked by the test build. Final builds ran sequentially and passed.
- Physical paired-device, small-Watch gestures, larger text and Crown checks were not run. No full unit-suite or Watch UI automation run is claimed.

## Resumed verification — November 2, 2026

Reviewed the existing implementation against the live STEEL-10 requirements. Corrected six untranslated Polish navigation strings. Re-ran the navigation tests: 8 passed, 0 failed (`/tmp/steel10-resume.xcresult`). Watch Debug and Release passed (`/tmp/steel10-resume-watch-debug.log`, `/tmp/steel10-resume-watch-release.log`); localization/catalog validation and `git diff --check` passed. Integrated join/resume acceptance depends on STEEL-9; physical-device gesture and larger-text acceptance remains outstanding.

## Code review — November 2, 2026

Independent review found two P2 blockers: remote uncompletion popped the correction screen and discarded its draft; removing the working set left a false empty state despite remaining sets. Fixed both in navigation reconciliation, including the related first-set-arrival case. Three new regression tests reproduced the defects before the fixes (six failed assertions across eleven navigation tests). Independent re-review found no remaining P1/P2 blockers in STEEL-10 scope.

Final verification after fixes:

- Full `Iron` unit suite: 120 passed, 0 failed, including 11 navigation tests (`/tmp/steel10-review-green.xcresult`, `/tmp/steel10-review-green.log`).
- Watch Debug and Release simulator builds passed (`/tmp/steel10-review-watch-Debug.log`, `/tmp/steel10-review-watch-Release.log`).
- Localization/catalog validation and `git diff --check` passed.
- The deliberately failing regression run completed its assertions but Xcode hung while finalizing diagnostics; its process was terminated. The failure evidence is in `/tmp/steel10-review-red.log`; that result bundle is not claimed complete. The successful full-suite run disabled extended diagnostics with `-collect-test-diagnostics never` and exited normally.

Paired join/resume acceptance and matching the HealthKit manager to the durable workout remain integration checks for STEEL-9. Physical small-Watch, larger-text and gesture checks remain outstanding; this review does not claim they passed.

## Pre-merge verification — November 2, 2026

Final independent review found no P1/P2 blockers within STEEL-10 scope. The complete unit suite passed again: 120 tests, 0 failures, on the existing iPhone 18 Pro simulator (`/tmp/steel10-premerge-existing.xcresult`). Watch Debug and Release builds passed (`/tmp/steel10-premerge-watch-Debug.log`, `/tmp/steel10-premerge-watch-Release.log`), along with localization/catalog validation and `git diff --check`. The initial test invocation could not find the earlier dedicated simulator; no tests ran in that attempt, and no replacement simulator was created.

The v0.9 wireframe describes the complete epic. This task ships its navigation and resume scaffolding; large Crown-editable fields, set saving/progression, correction saving and completion/record indicators remain STEEL-11/12. Shared finish/cancel remains STEEL-13. Full visual and paired-device acceptance is not claimed by this merge.
