# Testing

## Prerequisites

Use Xcode 27 or later with iOS 27 and watchOS 27 simulator runtimes. Follow the signing and app-group setup in the [README](../README.md). Keep simulator builds ad-hoc signed with `CODE_SIGN_IDENTITY=-`; disabling signing removes the app-group entitlement needed at startup.

The checked-in SwiftPM lockfile pins DGCharts to upstream revision `afc7c983d2f98c4d81cac28b1169951cc7323bb5`, which qualifies math functions with `Foundation` for the compiler. Use the recorded revision without patching downloaded package sources. The Watch app builds through the single executable `WatchIron` target.

## Static validation

Run from the repository root:

```sh
python3 scripts/validate-localization.py
git diff --check
```

The validator checks English/Polish resource and placeholder parity, resource syntax, production localization keys, Swift syntax, and exercise catalog identity, structure and translation coverage. Check target membership separately when adding resource files.

## Simulator builds and unit tests

List available destinations, then set `IRON_SIMULATOR_ID` to an iPhone simulator UUID from the output:

```sh
xcodebuild -project Iron.xcodeproj -scheme Iron -showdestinations
export IRON_SIMULATOR_ID='<simulator-uuid>'
```

Run the unit suite:

```sh
xcodebuild -project Iron.xcodeproj -scheme Iron \
  -destination "platform=iOS Simulator,id=${IRON_SIMULATOR_ID}" \
  -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- test
```

`IronTests` covers workout data, migrations, backup/import/export, chart rendering and localization behavior. `PolishLocalizationTests` checks language resolution, resource fallback, bilingual catalog search, custom content and stable exercise encoding. `IronBackupTests.testBackupAndWorkoutJSONKeepCanonicalNamesAcrossLanguages` compares full backup and workout JSON payloads across languages, including nested workout-plan references.

Build the Watch app separately:

```sh
xcodebuild -project Iron.xcodeproj -scheme WatchIron \
  -destination 'generic/platform=watchOS Simulator' \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGN_IDENTITY=- build
```

## iPhone UI tests

The shared `IronE2E` scheme drives the production app through XCUITest, without injecting stores, models or language defaults. Use a dedicated test simulator: tests change settings and create workouts. The workout and Siri scenarios require no active workout and stop if one already exists. Use generated data for testing and keep local exports and result bundles out of Git.

```sh
xcodebuild -project Iron.xcodeproj -scheme IronE2E \
  -destination "platform=iOS Simulator,id=${IRON_SIMULATOR_ID}" \
  -onlyUsePackageVersionsFromResolvedFile \
  -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- test
```

[`LocalizationE2ETests`](../IronE2ETests/LocalizationE2ETests.swift) includes:

- Language selection, English and Polish exercise search, detail rendering and language persistence after relaunch.
- A Polish workout with title persistence, exercise and set completion, finishing, and history verification after relaunch. The test handles both iOS Health authorization pages.
- Siri starting a workout, checked by verifying an actual active workout in Iron. Assistant UI alone does not satisfy the assertion. `voiceRecognitionText` supplies recognized text and does not test microphone input or speech recognition.

Use `-only-testing:IronE2ETests/LocalizationE2ETests/<test-method>` to select a scenario. Xcode result bundles include explicit screenshot and accessibility-tree attachments. For a reproducible failure, inspect these before changing queries or app behavior. `-collect-test-diagnostics never` skips extended simulator diagnostics while retaining test assertions and explicit attachments.

## Watch and Siri integration checks

The iPhone UI suite does not cover the complete Watch workout lifecycle. Use a paired iPhone and Watch for the following checks, with Health access granted on both:

1. Change language on the phone and verify Watch updates without a Watch-specific launch override. Repeat with Watch offline, then reconnect it.
2. Start a workout from the phone, confirm the companion launches, complete the workout and verify saved history.
3. Check authorized Health data, heart-rate readings and workout behavior in the background on physical devices.
4. Invoke Siri with a workout request naming Iron and verify that Iron creates a workout. Check app-owned localized responses separately from Siri's system language and voice.

Physical-device testing requires trusted devices with Developer Mode enabled and a development team/profile for the app, app group, HealthKit and Siri capabilities. Simulator builds and localized intent templates do not establish hardware sensor, background workout or spoken Siri behavior. Record device/OS versions and distinguish automated, manual and physical-device checks in test reports; store run-specific results with the issue or build artifacts.
