# Steel: Apple Developer setup

Steel is a separate installation from Iron, with separate sandbox, App Group, defaults and iCloud documents. No automatic Iron data migration is implemented or promised. Export a backup in Iron, explicitly import the compatible .ironbackup file in Steel and verify it before removing Iron. Grant Health permissions and configure Siri separately.

## Exact identifiers and capabilities

Register the five shipping explicit App IDs in the same verified developer team:

| Target | Bundle ID | Capabilities / configuration |
| --- | --- | --- |
| Iron (Steel) | cvgore.Steel | HealthKit (empty additional access list), Siri, App Groups, iCloud Documents, Time Sensitive Notifications |
| WatchIron (Steel) | cvgore.Steel.watchkitapp | HealthKit, workout-processing background mode; companion cvgore.Steel |
| IronWidgetExtension | cvgore.Steel.IronWidget | App Groups |
| IronIntents | cvgore.Steel.IronIntents | App Groups, existing Siri Intents extension |
| IronIntentsUI | cvgore.Steel.IronIntentsUI | App Groups, existing Siri Intents UI extension |

| Resource | Exact ID | Members / use |
| --- | --- | --- |
| App Group | group.cvgore.Steel | Iron, widget, Intents, Intents UI |
| iCloud container | iCloud.cvgore.Steel | Iron: CloudDocuments and ubiquity documents, not CloudKit |
| URL scheme | steel | Widget links and iPhone URL registration |

Other bundle IDs: cvgore.Steel.WorkoutDataKit (framework), cvgore.Steel.tests and cvgore.Steel.e2etests (tests); no separate shipping portal registration needed.

The Watch app uses the single executable WatchIron target; no separate Watch extension target needs provisioning.

Target/module names remain unchanged. Backup UTI com.kabouzeid.ironbackup, extension, MIME type, JSON and store models retain compatibility. Upstream author/contact/source/privacy/App Store destinations are preserved; no Steel listing or contact address is invented.

## Signing and installation

1. Add the user's Apple Developer account in Xcode Settings > Accounts and verify its actual team ID. The checked-in DEVELOPMENT_TEAM is inherited from upstream; replace it only with the verified team for your account.
2. Register the IDs/resources above in Certificates, Identifiers & Profiles. Enable each row's capabilities and associate the exact group/container.
3. Select the verified team on every shipping target, or pass its verified DEVELOPMENT_TEAM to xcodebuild. Preserve entitlements/background modes. Use automatic signing or install matching profiles and a certificate with its private key. Regenerate profiles after capability changes.
4. Trust/register the physical iPhone and paired Watch, enable Developer Mode and include both devices in development profiles. Build the Iron scheme with embedded Watch.
5. Archive for generic/platform=iOS with verified credentials; use -allowProvisioningUpdates only with an available account. Export with an ExportOptions.plist matching the distribution method, team and profiles. An ad-hoc signed simulator app is not a signed distributable IPA.

See Apple's [capability/profile instructions](https://developer.apple.com/help/account/identifiers/enable-app-capabilities) and [iCloud document setup](https://help.apple.com/xcode/mac/current/en.lproj/devcae40ccb9.html).

## Validation scope

Deployment minimums remain unchanged by this rebranding. Validate the final integrated build and signing configuration separately. Physical sensors, paired background behavior, spoken Siri and distribution require device validation.
