# Polish localization

Settings → General → Language offers Automatic / Polski / English. Automatic uses Polish when the primary system language is Polish and English otherwise. An explicit preference is stored in the existing app group for app, widget and Intents; Watch receives the latest preference through WatchConnectivity application context, including after offline activation. SwiftUI roots and Foundation strings/formatters use the selected locale. Legacy tab hosts also retain reactive locale handling without discarding navigation, sheets or draft state; the deployment minimum is now iOS 27.0.

All 159 built-in exercise titles, aliases, introductions, steps and tips have Polish presentation. Search indexes English and Polish titles/aliases in either display language, ignoring case, accents, `ł` and surrounding whitespace. Exercise UUIDs, numeric IDs, canonical muscle/equipment keys, references and image/PDF paths remain unchanged. Computed localized fields never change encoded backup content or exercise hashes. Custom exercise names/descriptions, workout titles, comments and other user-authored content are not translated. The English catalog is unchanged.

`Shared/Localization.swift` is compiled into app/extension targets and WorkoutDataKit. Shared en/pl resources include UI strings, plural rules, Siri intent templates, app-owned Health permission explanations and vocabulary. Dynamic labels use `L10n.string`/`L10n.format`; SwiftUI literals use the root locale. Motivational quotes, notification content (including pending notifications after switching), chart/model labels, Settings and accessibility labels are included. Siri voice/system chrome follows OS capabilities; localized intent templates are bundled, while app-owned exercise speakable names and hosted views use the selected preference.

Source catalog exceptions: ID 239 starts with an HTML-only `&nbsp;` slot, represented as a blank translated slot; IDs 237/291 have empty introductions in the source. These are inherited missing source content, not translation placeholders. Instructions otherwise retain ordered steps and tips. Existing contradictory source advice is translated rather than broadly rewritten; terminology and specific decisions are detailed in the implementation handoff.

## Validation

Real production-app UI E2E results and remaining Siri/Watch gaps: [2026-10-30 report](e2e-2026-10-30.md).

Run `python3 scripts/validate-localization.py` from the repository root. It validates UI/intent key and placeholder parity, resources, production localization keys, Swift syntax, all 159 catalog identities/schema/list counts, prose coverage and anatomy/equipment keys.

`IronTests/GeneralTests.swift` adds behavioral checks for language resolution/fallback, every built-in English/Polish search name, stable encoding, custom content isolation and actual SwiftUI language-switch snapshots. The existing migration, workout, backup and import/export suite remains enabled.

`IronBackupTests.testBackupAndWorkoutJSONKeepCanonicalNamesAcrossLanguages` restores the real v3 backup fixture and exports its workouts, plans and custom exercises in English and Polish. It verifies identical payloads (apart from the backup creation date), canonical `exerciseName` references in both encoders, stable identifiers and unchanged custom content while displayed built-in titles change. Exercise references use the source title for serialization, independently of localized presentation.

All project deployment targets now use iOS 27.0 / watchOS 27.0, matching the installed Xcode 27 SDKs. The Watch app migrated from the obsolete app-plus-WatchKit-extension arrangement to a single executable WatchIron target. Source files remain in their existing folders; the app keeps its companion bundle ID, HealthKit entitlement, background workout mode and localized resources. The extension target is no longer part of the project build graph.

DGCharts is pinned to upstream commit [`afc7c983d2f98c4d81cac28b1169951cc7323bb5`](https://github.com/ChartsOrg/Charts/commit/afc7c983d2f98c4d81cac28b1169951cc7323bb5), which qualifies the math functions with `Foundation` for newer Swift/SDK versions. The released 5.1.0 tag still contains the compiler error, so the project uses this immutable upstream revision rather than a moving branch. Imports and module-qualified chart types use `DGCharts`; the package has no transitive dependencies. The Xcode SwiftPM `Package.resolved` is checked in. No downloaded dependency source needs editing.

Shared schemes are checked in: `Iron` runs `IronTests`, `IronE2E` runs `IronE2ETests`, and `WatchIron` builds the standalone Watch app. For a fresh build, use new package/build directories; package resolution consumes the checked-in revision. For example:

```sh
xcodebuild -project Iron.xcodeproj -scheme Iron \
  -destination 'platform=iOS Simulator,id=42E753C7-7272-46F8-B3FF-150303B7D076' \
  -clonedSourcePackagesDirPath /tmp/iron-packages \
  -derivedDataPath /tmp/iron-build -jobs 4 CODE_SIGN_IDENTITY=- test
xcodebuild -project Iron.xcodeproj -scheme WatchIron \
  -destination 'generic/platform=watchOS Simulator' \
  -clonedSourcePackagesDirPath /tmp/iron-packages \
  -derivedDataPath /tmp/iron-watch -jobs 4 CODE_SIGN_IDENTITY=- \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64 build
```

Review-fix validation on 2026-10-31 used new package/build directories and the checked-in pin without dependency edits: generic iOS Simulator build PASS, standalone Watch simulator build PASS, `Iron` unit suite 39/39 PASS (including workout-history chart rendering), and `IronE2E` language/search/detail/relaunch scenario PASS. Logs, xcresult bundles and the rendered chart are retained in `.artifacts/review-fixes-2026-10-31/`. These checks resolve build/test reproducibility; they do not establish Siri routing or a full Watch workout lifecycle.

Simulator tests need ad-hoc signing so the app-group entitlement is retained; disabling signing causes the existing app startup to fail before tests. The post-migration iOS 27 test run and final connectivity-retry regression run passed all 38 tests: `/tmp/steel71-os27-tests.log` and `/tmp/steel71-os27-final-tests.log`, with results under `/tmp/steel71-os27/Logs/Test/`. This builds the single-target watchOS 27 app as an embedded companion too.

watchOS 27.0 runtime (24R362) is now installed. A connected simulator pair exists: iPhone 18 Pro `42E753C7-7272-46F8-B3FF-150303B7D076` + Steel QA Watch 27 `489A951D-1E68-4806-98CA-682C6FD8872D`, pair `B592D6F4-C1F7-4DE4-A434-0E3DF826AE03`. The Watch app installed and its process launched; screenshots show its idle screen in English and, with an explicit `-appLanguage pl` launch preference, in Polish (`/tmp/steel71-watch27-explicit-pl-ready.png`). The phone renders Polish (`/tmp/steel71-phone27-pl.png`). This proves local rendering, not phone-to-Watch preference transfer. At the integration checkpoint WCSession on the phone reported activated/paired but `isWatchAppInstalled == false`, so actual preference propagation is not counted as verified. Language transfer now retries on companion-installation and reachability changes, with an immediate-message path alongside durable application context.

Xcode 27 supplies Device Hub at `/Applications/Xcode.app/Contents/Applications/DeviceHub.app` (bundle `com.apple.dt.Devices`) rather than the former Simulator.app. The earlier description of a stripped GUI installation was incorrect. Accessibility and screen capture are confirmed working when addressing Device Hub by its exact process/window and using `--restore-window` (verified AX tree and screenshot on 2026-10-16). The earlier blanket permission diagnosis was incorrect: Finder had no AX windows and the tool classified failed window discovery as permission_denied. No TCC database changes are required. On 2026-10-16 the concrete GUI failure was in Apple Device Hub/CoreSimulator: the device view stays at “Connecting display…” and SimulatorViewProvider logs a 30-second timeout “without a matching screen”, with resolvedTargetUniqueId and deviceInfo.displayInfo nil despite known screen IDs. Direct simctl screenshots work. Restarting Device Hub and the scoped CoreSimulator service did not resolve the display bridge then. On 2026-10-30 Device Hub displays the devices successfully; this is no longer the current E2E blocker. Microphone permission is only relevant if testing live audio input; typed or injected Siri requests do not establish microphone/voice recognition quality.

No physical iPhone or Watch is connected, and `security find-identity -v -p codesigning` reports zero valid signing identities. For on-device HealthKit/heart-rate/background-workout and live Siri voice validation, connect a paired iPhone + Watch, enable Developer Mode on both, trust the Mac, and configure a signing team/profile for the existing app/group/HealthKit/Siri capabilities. Simulator execution, compilation and localized Siri templates do not prove hardware sensor or spoken Siri behavior.

## Terminology sources

Only Polish Wikipedia was used for external terminology research. These are the exact successfully opened page URLs; source instructions remain translations of the repository data rather than copied Wikipedia prose. No other website, linked reference, or image source was used.

- https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_naramienny — deltoid: mięsień naramienny.
- https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_tr%C3%B3jg%C5%82owy_ramienia — triceps brachii: mięsień trójgłowy ramienia.
- https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_dwug%C5%82owy_ramienia — biceps brachii: mięsień dwugłowy ramienia.
- https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_najszerszy_grzbietu — latissimus dorsi: mięsień najszerszy grzbietu.
- https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_czworoboczny — trapezius: mięsień czworoboczny.
- https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_piersiowy_wi%C4%99kszy — pectoralis major: mięsień piersiowy większy.
- https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_czworog%C5%82owy_uda — quadriceps: mięsień czworogłowy uda.
- https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_brzuchaty_%C5%82ydki — gastrocnemius: mięsień brzuchaty łydki.
- https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_p%C5%82aszczkowaty — soleus: mięsień płaszczkowaty.
- https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_po%C5%9Bladkowy_wielki — glutaeus maximus: mięsień pośladkowy wielki.
- https://pl.wikipedia.org/wiki/Mi%C4%99sie%C5%84_prostownik_grzbietu — erector spinae: prostownik grzbietu.
- https://pl.wikipedia.org/wiki/Przysiad — resolves to Przysiady; przysiad, mięśnie kulszowo-goleniowe, and muscle terminology.
- https://pl.wikipedia.org/wiki/Martwy_ci%C4%85g — martwy ciąg.
- https://pl.wikipedia.org/wiki/Podci%C4%85ganie_na_dr%C4%85%C5%BCku — podciąganie, nachwyt, podchwyt, chwyt neutralny (młotkowy).
- https://pl.wikipedia.org/wiki/Plank — deska.
- https://pl.wikipedia.org/wiki/Pompki_na_por%C4%99czach — pompki na poręczach.
- https://pl.wikipedia.org/wiki/Wznosy_bokiem — wznosy/unoszenie bokiem.
- https://pl.wikipedia.org/wiki/Hantle — hantle.
- https://pl.wikipedia.org/wiki/Sztanga — sztanga/gryf.

Attempts to open Wyciskanie_sztangi and Wyciskanie_leżąc returned browser internal errors and were not used as verified sources. Search returned no results, so terminology pages were opened directly.


## Real UI regression (2026-10-16)

`IronE2ETests/LocalizationE2ETests.swift` runs the production app without injected stores or view factories. The language/search test initially exposed SIGABRT in `UIImage.tinted(with:)` when opening exercise details. The tint helper now uses `withTintColor`, and PDF rendering skips nonpositive/nonfinite layout sizes. Re-running `testLanguageSwitchAndBilingualExerciseSearch` on iOS 27 passed: 1 test, 0 failures, 51.9 seconds. It covers Polish selection, English and Polish search, exercise detail rendering, English selection and persistence after relaunch. Result bundle: `/tmp/steel71-e2e-language-fixed.xcresult`. This result does not establish Watch connectivity or Siri E2E success.
