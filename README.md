# QR Scanner

The built-in iOS QR scanner doesn't let you zoom. This one does.

## Features

* 1×–10× zoom
* One-finger drag gesture for zoom control
* Automatic switching between Wide and Telephoto cameras
* Automatic opening when a single QR code is detected
* Tap to choose when multiple QR codes are detected
* Fully on-device processing
* No analytics, backend, or scan history
* No third-party dependencies

## Installation

Requires **iOS 17+**.

Unsigned IPA builds are available from [Releases](../../releases) and can be installed using tools such as Sideloadly.

## Build

```bash
xcodegen generate
```

Built with SwiftUI and AVFoundation.
