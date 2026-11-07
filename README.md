# WallView

WallView is an iOS augmented-reality prototype for previewing how an artwork image could look on a real wall. It uses the device camera to place a selected image in the physical environment.

## What it explores
- AR-based visualization for art and interior spaces
- Camera-assisted placement on real surfaces
- Choosing artwork from the photo library
- A focused, device-first iOS experience

## Built with
- Swift
- ARKit
- iOS 17+
- XcodeGen

## Run locally
1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2. Run `xcodegen generate` from the project root.
3. Open `WallView.xcodeproj` in Xcode.
4. Build and run on an ARKit-compatible iPhone or iPad.

WallView requests camera access for AR placement and photo-library access to select and save artwork previews.

## Status
Early prototype. The repository currently focuses on the core AR viewing experience.
