<p align="center">
  <a href="https://apps.apple.com/us/app/iron-workout-tracker/id1479893244?itsct=apps_box_link&itscg=30200" target="_blank" rel="noopener noreferrer">
    <img width="180" height="180" src="assets/app_icon_rounded.png" alt="Iron App Icon">
  </a>
</p>

<p align="center">
  <a href="https://apps.apple.com/us/app/iron-workout-tracker/id1479893244?itsct=apps_box_badge&amp;itscg=30200" target="_blank" rel="noopener noreferrer"><img src="assets/Download_on_the_App_Store_Badge_US-UK_RGB_blk_092917.svg" alt="Download on the App Store" style="width: 160px"></a>
</p>

# Iron

A modern and completely free weightlifting workout tracker for iOS, written in SwiftUI.

| ![Screenshot 1](assets/screenshot1.png) | ![Screenshot 2](assets/screenshot2.png) | ![Screenshot 3](assets/screenshot3.png) |
|-|-|-|

## Building

**Xcode 27** or later is required. Deployment targets are **iOS 27.0** and **watchOS 27.0**. Open `Iron.xcodeproj`; the shared schemes are `Iron` (app and unit tests), `IronE2E` (UI tests), and `WatchIron` (Watch app).

- Select the "Iron" project in the Xcode sidebar
- Under "Targets", select "Iron"
- Change the "Bundle Identifier", "App Group" and "iCloud Container" to something unique like `com.yourname.Iron`
- Go to the "Signing & Capabilities" tab and select your development team under "Signing > Team"
- Repeat the same process for the other targets where applicable
- Build the `Iron` scheme.

DGCharts is pinned to an upstream compiler fix in the checked-in SwiftPM lockfile. Resolve the recorded dependency version without editing downloaded package sources.

See [Testing](docs/testing.md) for simulator commands and device checks, and [Localization](docs/localization.md) for language behavior, resources and catalog maintenance.
