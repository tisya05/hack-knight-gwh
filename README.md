# Echora

Echora is a spatial-audio object finder for blind and low-vision users. The
shared architecture, module ownership, and feature contract live in
[`docs/CONTRACT.md`](docs/CONTRACT.md).

## Run the app locally

Each teammate signs the app with their own Apple ID. Do not share Apple IDs,
certificates, provisioning profiles, `Local.xcconfig`, or `Secrets.xcconfig`.

### One-time setup

1. Install Xcode 16.4 or later from the App Store and launch it once to accept
   its license.
2. Install XcodeGen:
   ```sh
   brew install xcodegen
   ```
3. Create your ignored local signing settings:
   ```sh
   cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig
   ```
   Edit `ios/Config/Local.xcconfig` with the development team ID shown in
   Xcode and a unique suffix such as `.moon` or `.qimin`.
4. In Xcode, sign in with your own Apple ID: **Xcode -> Settings -> Accounts**.
   A free Personal Team is enough for on-device development.

### Build and run

From a current branch:

```sh
xcodegen generate
xcodebuild -scheme Echora -destination 'generic/platform=iOS Simulator' build
```

Open `Echora.xcodeproj` (it is generated and intentionally ignored by Git).
Never edit or commit the generated project file; make project changes in
`project.yml`, then regenerate it.

To run on an iPhone:

1. Enable **Developer Mode** on the phone, then connect and unlock it.
2. Accept the **Trust This Computer** prompt.
3. In Xcode, select the **Echora** target, open **Signing & Capabilities**,
   enable **Automatically manage signing**, and choose your Personal Team.
4. Select the phone in the run-destination menu and press **Command-R**.
5. If iOS asks, trust the developer app in **Settings -> General -> VPN &
   Device Management**, then run again.

By default the app uses all mocks. Seeing the operator screen on the phone is
the device smoke test: Xcode, signing, installation, and the generated project
all work. Turn on the real modules you want to test with the next section.

### Use real services on your phone

`main` always builds with mocks. Each person picks which services run for real
on **their own** builds in their ignored `ios/Config/Local.xcconfig`:

```
// Space separated. Names: perception locator headTracking audio voice narrator telemetry
ECHORA_REAL_SERVICES = perception audio headTracking
```

- Rebuild (Command-R) after changing it; no need to regenerate the project.
- Real `perception` needs a phone. In the simulator it falls back to the mock.
- A service that has no real implementation yet stays a mock.
- One-off override without editing the file: add a launch argument in the
  Xcode scheme, e.g. `-flag.mockPerception NO`.

Typical setups: everything real for the full app
(`perception locator headTracking audio`), or only your own module plus
`perception audio` to hear it on device.

### Gemini key and free-tier limits

`locator` (Gemini) needs your own key in the ignored
`ios/Config/Secrets.xcconfig`:

```
GEMINI_API_KEY = your-key-here
```

No quotes. Get a key at aistudio.google.com -> Get API key.

The free tier is small, so spend requests on purpose:
- The app uses the **Flash Lite** models (500 requests/day each). Full Flash
  models are only 20/day on the free tier.
- Each Ask is one request, two if Gemini is slow and the app races the backup model.
- Limits reset at midnight Pacific (3 AM Eastern). Check usage at
  aistudio.google.com -> Rate Limit.
- Leave `locator` out of `ECHORA_REAL_SERVICES` unless you are testing Gemini.
  The mock locator answers "the object is in the center of the photo".
- Unit tests never call the network. Don't add tests or loops that do.

### Debug switches

Stored in `UserDefaults` (the Settings screen should expose them; launch
arguments like `-debug.showMarkers NO` also work):

| Key | Default | Effect |
|---|---|---|
| `debug.showMarkers` | on | Target spheres, the on-camera readout, and the **Test mode** button. Turn off for demos. |
| `debug.disableLiDAR` | off | Snapshots without depth, to test the non-LiDAR (table-surface) placement path. |
| `flag.mockPerception`, `flag.mockLocator`, `flag.mockHeadTracking`, `flag.mockAudio`, `flag.mockVoice`, `flag.mockNarrator`, `flag.mockTelemetry` | from `Local.xcconfig` | Per-service mock override. |

**Test mode** (top-right of the camera view, debug only): when ON, every tap
also runs the full photo -> 3D pipeline. Red = direct tap, blue = LiDAR path,
green = non-LiDAR path; the readout shows how far blue and green land from red.

### Live dashboard

`live-dashboard/` shows a search live on a laptop (snapshot + box, top-down map,
head direction, numbers). Run `python3 live-dashboard/server.py` and set
`ECHORA_LIVE_URL` in `Local.xcconfig`. See `live-dashboard/README.md`.

### Before opening a PR

```sh
git fetch origin
git merge origin/main
xcodegen generate
xcodebuild -scheme Echora -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme Echora -destination 'platform=iOS Simulator,name=<installed iPhone>' test
```

Follow the branch, ownership, and pull-request rules in `CLAUDE.md` and the
contract. In particular, never commit generated `.xcodeproj` files or local
configuration/secrets.
