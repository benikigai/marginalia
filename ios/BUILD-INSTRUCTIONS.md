# Marginalia iOS — Build Instructions

## Prerequisites
- MacBook Pro with Xcode 16+ installed
- iPhone 17 Pro Max connected via USB
- Apple Developer account (free is fine for personal device)

## Step 1: Build the Cactus XCFramework

```bash
cd /tmp
git clone --depth 1 https://github.com/cactus-compute/cactus.git
cd cactus
bash apple/build.sh
```

This produces: `apple/build/cactus-ios.xcframework`

If the build script fails, check:
- Xcode is selected: `sudo xcode-select -s /Applications/Xcode.app`
- iOS SDK exists: `xcrun --show-sdk-path --sdk iphoneos`

## Step 2: Create Xcode Project

1. Open Xcode → File → New → Project → iOS → App
2. Name: `Marginalia`, Bundle ID: `com.marginalia.app`
3. Interface: SwiftUI, Language: Swift
4. Delete the generated ContentView.swift

## Step 3: Add Files

Copy these files from `ios/Marginalia.swiftpm/Sources/` into the Xcode project:
- `MarginaliaApp.swift` (replaces the generated @main App)
- `InferenceEngine.swift`
- `LocalServer.swift`
- `Cactus.swift`

## Step 4: Add Cactus Framework

1. Drag `cactus-ios.xcframework` into the Xcode project navigator
2. In target → General → "Frameworks, Libraries, and Embedded Content":
   - Set `cactus-ios.xcframework` to "Embed & Sign"

## Step 5: Add Swifter HTTP Server

1. File → Add Package Dependencies
2. URL: `https://github.com/httpswift/swifter.git`
3. Version: Up to Next Major, 1.5.0
4. Add to target: Marginalia

## Step 6: Build the Glasses Web App

```bash
cd /path/to/marginalia/glasses
npm run build
```

This produces `glasses/dist/`. Copy the contents into the Xcode project:
1. Create a folder reference called "GlassesApp" in the project
2. Drag the contents of `glasses/dist/` into it
3. Also copy `server/static/calendar.html` into `GlassesApp/static/`
4. Ensure "Copy Bundle Resources" includes the GlassesApp folder

## Step 7: Pre-load Model Weights

The models are too large to bundle in the app. Pre-load them via Xcode:

### Option A: iTunes File Sharing
1. In Info.plist, add `UIFileSharingEnabled = YES` and `LSSupportsOpeningDocumentsInPlace = YES`
2. Build and run the app once (to create the Documents directory)
3. In Finder → iPhone → Files → Marginalia, create `models/` folder
4. Copy model directories:
   - `models/parakeet-tdt-0.6b-v3/` (from Cactus weights)
   - `models/gemma-4-e2b-it/` (from Cactus weights)

### Option B: Xcode Device Window
1. Window → Devices and Simulators → select iPhone
2. Select Marginalia app → click gear → Download Container
3. Add models to `Documents/models/` in the container
4. Replace container

### Where are the model weights?
On the Mac Mini they're at:
```
/opt/homebrew/Cellar/cactus/1.14_1/libexec/weights/gemma-4-e2b-it
/opt/homebrew/Cellar/cactus/1.14_1/libexec/weights/parakeet-tdt-0.6b-v3
```

Copy them to the MacBook Pro first:
```bash
scp -r elias@100.85.105.99:/opt/homebrew/Cellar/cactus/1.14_1/libexec/weights/gemma-4-e2b-it ./models/
scp -r elias@100.85.105.99:/opt/homebrew/Cellar/cactus/1.14_1/libexec/weights/parakeet-tdt-0.6b-v3 ./models/
```

## Step 8: Configure & Run

1. Select your iPhone as the build target
2. Build & Run (Cmd+R)
3. On iPhone, the app shows model loading status
4. Once models are loaded, the HTTP server starts on localhost:8080

## Step 9: Connect G2 Glasses

1. Open Even Realities app on the same iPhone
2. Ensure G2 glasses are paired and connected
3. In Even Realities developer/sideload, enter URL:
   `http://localhost:8080/glasses/?server=localhost:8080`
4. The glasses app loads from the iPhone's local server
5. Everything is on-device — zero network traffic

## Architecture

```
┌──────────┐        BLE         ┌─────────────────────────────┐
│ G2       │◄──────────────────►│ iPhone 17 Pro Max           │
│ Glasses  │                    │                             │
│          │                    │ Even Realities App          │
│ - Mic    │──PCM──────────────►│   └── WebView               │
│ - Lens   │◄──text─────────────│       loads localhost:8080   │
│ - R1 Ring│──tap──────────────►│       │ HTTP (loopback)      │
│          │                    │       ▼                      │
│          │                    │ Marginalia App              │
│          │                    │   ├── HTTP Server (:8080)    │
│          │                    │   ├── Cactus Parakeet STT    │
│          │                    │   └── Cactus Gemma 4 E2B     │
└──────────┘                    └─────────────────────────────┘

MacBook: build machine + projector (AirPlay mirror iPhone)
```

## Troubleshooting

**"cactus module not found"**: Ensure Cactus.swift is in the project AND the XCFramework is linked.

**Models not loading**: Check Documents/models/ exists. Enable file sharing in Info.plist. Check console for path logs.

**Server won't start**: Port 8080 might be in use. Kill other apps. Check for port conflicts.

**Even Realities WebView won't load localhost**: Try `http://127.0.0.1:8080` instead. Some WebViews block localhost.

**Inference too slow**: Enable dummy mode in the app UI. The demo will use pre-loaded responses.
