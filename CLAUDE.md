# Echo (Hack Knight 2026)

Spatial-audio object finder for blind and low-vision users. Read docs/CONTRACT.md before doing anything. It is the source of truth for types, protocols, ownership, and conventions.

## Hard rules
- Only edit files in folders owned by the person you are working with (docs/CONTRACT.md Part 6.1). If a change is needed elsewhere, write down exactly what is needed and tell the user to ask the owner.
- Never change ios/Echo/Contracts/ without the user explicitly confirming the team agreed. Additive changes only.
- Swift 5 language mode. @MainActor on coordinator and UI-facing classes.
- Readable multi-line code. No one-liners, no long chains, no force unwraps outside Config.
- main must build with all-mocks flags. Run `xcodegen generate` then build and tests before saying something is done.
- Never commit secrets (Secrets.xcconfig, Local.xcconfig, .env) or the generated .xcodeproj.
- ARKit, camera, and AirPods do not work in the simulator. For device code, add logging and a visible debug readout so the human can test on a phone quickly.
- Coordinate conventions (CONTRACT Part 2.3): ARKit world space, meters, +Y up. Upright normalized image space. Gemini box_2d is [ymin, xmin, ymax, xmax] on 0-1000. Yaw + = left. Display angle + = right (use Geometry helpers).

## Commands
- Generate project: `xcodegen generate`
- Build: `xcodebuild -scheme Echo -destination 'generic/platform=iOS Simulator' build`
- Test: `xcodebuild -scheme Echo -destination 'platform=iOS Simulator,name=<any installed iPhone>' test`
- Backend: see backend/README.md

## Kickoff prompts for each teammate's Claude Code session
- Seoyeon: "Read CLAUDE.md and docs/CONTRACT.md. I'm Seoyeon. I own HeadTracking/ and Audio/. Implement Part 4.3 and 4.4, starting with SpatialAudioEngine and ListenerPoseMath for Layer 1, then HeadTracker. Work on branch seoyeon/audio."
- Moon: "Read CLAUDE.md and docs/CONTRACT.md. I'm Moon. I own Voice/, Telemetry/, backend/, and dashboard/ code. Start with the backend (Part 5) and deploy it, then TelemetryClient, VoiceCommandListener, DirectionsPhraser with tests, DirectionsNarrator. Work on branch moon/backend and moon/voice."
- Qimin: "Read CLAUDE.md and docs/CONTRACT.md. I'm Qimin. I own UI/ and Resources/Sounds/, plus the dashboard design. Build Part 4.10 against all-mocks flags, starting with OperatorView. Work on branch qimin/ui."
- Tisya: "Read CLAUDE.md and docs/CONTRACT.md. I'm Tisya. I own App/, Perception/, project.yml, ios/Config/. Implement Part 4.1 and 4.2 in the order given in Part 0 step 10. Work on branch tisya/perception."
