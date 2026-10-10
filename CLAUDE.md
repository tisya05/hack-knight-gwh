# Echora (Hack Knight 2026)

Spatial-audio object finder for blind and low-vision users. Read docs/CONTRACT.md before doing anything. It is the source of truth for types, protocols, ownership, and conventions.

## Hard rules
- Only edit files in folders owned by the person you are working with (docs/CONTRACT.md Part 6.1). If a change is needed elsewhere, write down exactly what is needed and tell the user to ask the owner.
- Never change ios/Echora/Contracts/ without the user explicitly confirming the team agreed. Additive changes only.
- Swift 5 language mode. @MainActor on coordinator and UI-facing classes.
- Readable multi-line code. No one-liners, no long chains, no force unwraps outside Config.
- main must build with all-mocks flags. Run `xcodegen generate` then build and tests before saying something is done.
- Never commit secrets (Secrets.xcconfig, Local.xcconfig, .env) or the generated .xcodeproj.
- ARKit, camera, and AirPods do not work in the simulator. For device code, add logging and a visible debug readout so the human can test on a phone quickly.
- GitHub workflow (CONTRACT Part 6.2): never commit or push to `main`. For every feature, branch from fresh `main` as `<name>/<feature>` (e.g. `tisya/tap-to-place`), commit there, push, and open a pull request with `gh pr create --base main`. Before the PR: merge `origin/main`, `xcodegen generate`, build, test. Do not merge unless the user explicitly says to; then squash merge and delete the branch. Give the user the PR link.
- Coordinate conventions (CONTRACT Part 2.3): ARKit world space, meters, +Y up. Upright normalized image space. Gemini box_2d is [ymin, xmin, ymax, xmax] on 0-1000. Yaw + = left. Display angle + = right (use Geometry helpers).

## Commands
- Generate project: `xcodegen generate`
- Build: `xcodebuild -scheme Echora -destination 'generic/platform=iOS Simulator' build`
- Test: `xcodebuild -scheme Echora -destination 'platform=iOS Simulator,name=<any installed iPhone>' test`
- Backend: see backend/README.md
- Real services on a device: `ECHORA_REAL_SERVICES` in the gitignored `ios/Config/Local.xcconfig` (see README). Never change `Config.defaultFlags`; main stays all-mocks.
- Gemini free tier is tight (Flash Lite 500/day per model, Flash 20/day). Don't spend real Gemini requests in tests, loops, or exploratory scripts; use `MockObjectLocator` and fixtures. Never print or commit the key.
- Debug switches (`debug.showMarkers`, `debug.disableLiDAR`, `flag.mock*`) are listed in README.

## Kickoff prompts for each teammate's Claude Code session
- Seoyeon: "Read CLAUDE.md and docs/CONTRACT.md. I'm Seoyeon. I own HeadTracking/, Audio/, Voice/VoiceCommandListener.swift and Voice/DirectionsNarrator.swift. Audio and head tracking are merged; next: cue tuning, then VoiceCommandListener (Part 4.5), then DirectionsNarrator (Part 4.6). One branch and one PR per feature, e.g. seoyeon/voice-listener, seoyeon/directions-narrator."
- Moon: "Read CLAUDE.md and docs/CONTRACT.md. I'm Moon. I own Voice/DirectionsPhraser.swift, Telemetry/, backend/, and dashboard/ code. Start with the backend on Tiger Data (Part 4.8, Part 5) and deploy it, then TelemetryClient, then DirectionsPhraser with tests. One branch and one PR per feature, e.g. moon/backend, moon/telemetry-client, moon/directions-phraser."
- Qimin: "Read CLAUDE.md and docs/CONTRACT.md. I'm Qimin. I own UI/ and Resources/Sounds/, plus the dashboard design. Build Part 4.10 against all-mocks flags, starting with OperatorView. One branch and one PR per feature, e.g. qimin/operator-view, qimin/debug-panel, qimin/cue-sounds."
- Tisya: "Read CLAUDE.md and docs/CONTRACT.md. I'm Tisya. I own App/, Perception/, project.yml, ios/Config/. Implement Part 4.1 and 4.2 in the order given in Part 0 step 10. One branch and one PR per feature, e.g. tisya/tap-to-place, tisya/ray-math, tisya/snapshot-capture, tisya/gemini-locator."
