# JumpShot for iPhone

Native SwiftUI app: detects a jump in the camera preview with Apple Vision body-pose
detection and shoots a burst of full-quality photos into a "JumpShot" album in Photos.
Same jump detector as the Android and web versions.

Requires iOS 16+. No third-party libraries.

## Build on a Mac
    brew install xcodegen
    cd ios && xcodegen generate
    open JumpShot.xcodeproj
Pick your team under Signing & Capabilities, plug in the iPhone, press Run.

## Build without a Mac
The GitHub Actions workflow `.github/workflows/ios.yml` builds an unsigned
`JumpShot-unsigned.ipa` on a macOS runner (Actions tab → latest "iOS build" run → Artifacts).
Install it from Windows with Sideloadly or AltStore, which sign it with your Apple ID.
With a free Apple ID the app must be re-installed every 7 days.

## Files
- JumpShotApp.swift, ContentView.swift: app and camera screen
- CameraModel.swift: AVFoundation session, Vision pose detection, burst capture
- JumpDetector.swift: the jump detector
- CameraViews.swift: preview, skeleton overlay, jump-figure icon
- SettingsView.swift, Settings.swift: settings screen and stored values
- PhotoLibrary.swift: saving to the JumpShot album, latest thumbnail
