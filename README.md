<p align="center">
  <img width="180" height="180" src="assets/app_icon_rounded.png" alt="Steel App Icon">
</p>

# Steel

A modern and completely free weightlifting workout tracker for iOS, written in SwiftUI.

| ![Screenshot 1](assets/screenshot1.png) | ![Screenshot 2](assets/screenshot2.png) | ![Screenshot 3](assets/screenshot3.png) |
|-|-|-|

## Building

**Xcode 27** or later is required. Deployment targets are **iOS 26.0** and **watchOS 26.0**. Open `Iron.xcodeproj`; the shared schemes are `Iron` (app and unit tests), `IronE2E` (UI tests), and `WatchIron` (Watch app).

Follow [Apple Developer setup](docs/apple-developer.md) for the exact Steel identifiers, capabilities and signing steps. Build the existing `Iron` scheme; target/module names remain unchanged.

DGCharts is pinned to an upstream compiler fix in the checked-in SwiftPM lockfile. Resolve the recorded dependency version without editing downloaded package sources.

See [Testing](docs/testing.md) for simulator commands and device checks, and [Localization](docs/localization.md) for language behavior, resources and catalog maintenance.
