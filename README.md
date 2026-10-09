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

The initial app uses all mocks. Seeing the operator screen on the phone is the
device smoke test: Xcode, signing, installation, and the generated project all
work. ARKit placement, LiDAR, AirPods head tracking, spatial audio, voice, and
backend checks start as their real modules land.

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
