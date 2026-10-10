# Echora: Build Contract

Repo: https://github.com/tisya05/hack-knight-gwh
Event: Hack Knight 2026, Queens College, Oct 9-11
Team: Tisya (Perception: Gemini + ARKit, integration lead), Seoyeon (Head tracking + spatial audio), Moon (Full stack: backend, dashboard, voice, telemetry, spoken-directions baseline), Qimin (Design, UI/UX, sound design)

This document is the single source of truth for types, protocols, ownership, and conventions. Changes follow Part 6.3.

---

## PART 1. Product spec

### 1.1 One line
Echora helps blind and low-vision people find objects with sound instead of words. You ask for an object, and a sound plays from where that object actually is. Echora does not talk.

### 1.2 The demo we are building toward (about 2 minutes per judge)
1. One-sentence intro, then "try it first."
2. Judge sits at the table, puts on AirPods (or wired earphones) and a disposable sleep mask. We frame it as "testing an audio-only interface," not "experiencing blindness."
3. We place 4 or 5 objects on the table after the mask is on.
4. Round A: judge asks for an object. Spoken-directions mode (clock-face directions, updated every 4 seconds). Timed until they touch it.
5. We move the objects.
6. Round B: judge asks for an object. Echora mode (spatial audio cue only). Timed.
7. Mask off. The booth dashboard shows their two times and the running averages across every visitor this weekend.
8. Mode order alternates per participant (odd IDs: spoken first, even IDs: Echora first) so learning does not bias the result.

### 1.3 Build layers (each one is a complete demo on its own)
| Layer | What works | Owners |
|---|---|---|
| 1 (GO/NO-GO) | Tap the table on screen, a looping sound is anchored there and stays put when the phone or head turns. No AI. | Tisya, Seoyeon |
| 2 | Typed request ("mug") -> Gemini finds it -> sound plays from it | Tisya |
| 3 | Voice request (push-to-talk) | Moon |
| 4 | Spoken-directions comparison mode + round timer + results to backend | Moon, Tisya |
| 5 | AirPods head tracking, proximity/alignment cue rate, live dashboard, polish | Seoyeon, Moon, Qimin |

Floor fallback if 3D placement fails: the ray from the detection is placed at a fixed 0.6 m depth (`PlacementMethod.fixedDepthFallback`). This gives correct left/right direction with zero plane detection and uses the same code path, so it always exists.

### 1.4 Physical rig (decision)
The phone sits on a small stand or tripod on the table directly in front of the judge, at roughly chest height, back camera facing the table, so the whole tabletop is in frame. **Current setup (no stand available):** the judge holds the phone at chest height like taking a photo of the table, or it leans upright against a box / books. The `standInFront` offsets (0.35 m back, 0.30 m up) fit handheld use, and with AirPods the listener direction comes from the head, not the phone (3.6). The operator (a teammate) sits beside the judge and taps the screen. We are NOT using a chest lanyard as the default because the screen would face the judge's body and the operator could not run rounds. Chest mount stays supported as `ListenerRig.chestMount` in case we need it.

Because the phone is not at the judge's head, the listener position is the phone position shifted back toward the judge and up to ear height (`ListenerRig.standInFront`).

### 1.5 Out of scope this weekend
Room-scale walking navigation, full room pre-scan and object memory, hand tracking, Android, shipping to the App Store, Presage, ElevenLabs (unless a cue sound genuinely needs it). Room scan goes in the pitch as "what's next."

---

## PART 2. Architecture

### 2.1 Data flow
```
Request (voice or typed)
   |
   v
EchoraCoordinator ---captureSnapshot()---> PerceptionService
   |                                   (copies JPEG + camera transform + intrinsics, releases ARFrame)
   v
ObjectLocator.locate(utterance, snapshot)  --HTTPS-->  Gemini
   |   returns Detection (upright normalized box)
   v
PerceptionService.place(detection, snapshot)
   |   ray from saved camera -> ARKit raycast -> AnchoredTarget (world position, meters)
   v
Mode == .echora:   SpatialAudioRendering.setTarget(target)
Mode == .spoken: DirectionsNarrating.start(target)
   |
   v
Round timer starts when guidance output begins. Operator taps FOUND. RoundResult -> TelemetryReporting -> backend -> dashboard
```

### 2.2 The real-time loop (about 60 Hz, main thread)
```
PerceptionService.onBodyPoseUpdate(bodyPose)
   -> head = HeadTracking.currentRotation()
   -> listener = ListenerPoseMath.compose(body, head, rig)
   -> SpatialAudioRendering.updateListener(listener)
   -> cue = CueModulator.parameters(listener, target)
   -> SpatialAudioRendering.updateCue(cue)
   -> debug info updated (throttled to 10 Hz for UI)
```
Gemini is called once per request, never per frame. The target position is fixed once placed. Only the listener pose changes in real time.

### 2.3 Coordinate conventions (everyone must follow these)
- World space is ARKit world space: right-handed, meters, +Y up, -Z is the camera's initial forward. `AVAudioEnvironmentNode` uses the same right-handed convention, so world coordinates are passed to audio unchanged.
- `NormalizedPoint` / `NormalizedRect` are in UPRIGHT image space (the image as a human sees it when the phone is held portrait). (0,0) is top-left, (1,1) is bottom-right.
- Gemini returns `box_2d` as `[ymin, xmin, ymax, xmax]` on a 0-1000 scale. The locator converts to `NormalizedRect` immediately. Nothing else in the app sees the 0-1000 format.
- Yaw: positive = turned LEFT (counterclockwise seen from above), in radians. Pitch: positive = looking UP.
- Horizontal angle to a target (for cues, debug, and spoken directions): degrees, positive = target is to the RIGHT of forward. Yes this is the opposite sign of yaw. It is only used for human-facing output. Use the helper `Geometry.signedHorizontalAngleDegrees` so nobody re-derives it.

---

## PART 3. Shared contract (`ios/Echora/Contracts/`)

These files are frozen after `contracts v1`. Everyone codes against them. Owners implement the protocols in their own folders.

### 3.1 `Contracts/Models.swift`
```swift
import Foundation
import simd
import CoreGraphics

// MARK: - Image space

/// Normalized point in UPRIGHT image space. (0,0) top-left, (1,1) bottom-right.
struct NormalizedPoint: Codable, Equatable {
    var x: Double
    var y: Double
}

/// Normalized rect in UPRIGHT image space.
struct NormalizedRect: Codable, Equatable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    var center: NormalizedPoint {
        NormalizedPoint(
            x: (minX + maxX) / 2.0,
            y: (minY + maxY) / 2.0
        )
    }

    /// Where the object meets the table. Used for raycasting so the ray
    /// hits the table at the object's base instead of behind the object.
    var baseCenter: NormalizedPoint {
        let height = maxY - minY
        return NormalizedPoint(
            x: (minX + maxX) / 2.0,
            y: maxY - (0.1 * height)
        )
    }
}

/// How the sensor image must be rotated to become upright.
enum UprightRotation: String, Codable {
    case portrait
    case landscapeRight
}

// MARK: - Perception

struct Detection: Codable, Equatable {
    var label: String            // what Gemini says it found, e.g. "blue mug"
    var box: NormalizedRect      // upright normalized
    var confidence: Double?      // 0...1 if provided
}

/// Copy of the LiDAR depth map at capture time (sensor orientation, e.g. 256 x 192).
/// Nil on phones without LiDAR.
struct DepthSnapshot {
    let width: Int
    let height: Int
    let depthMeters: [Float]              // row-major, width * height
    let confidence: [UInt8]               // ARConfidenceLevel raw values: 0 low, 1 medium, 2 high
}

/// Everything needed to turn a pixel in THIS photo into a 3D point later,
/// even after the phone has moved. Never store the ARFrame itself.
struct Snapshot {
    let id: UUID
    let capturedAt: Date
    let uprightJPEG: Data                 // sent to Gemini, long edge <= 1024 px
    let cameraTransform: simd_float4x4    // ARCamera.transform at capture time
    let intrinsics: simd_float3x3         // ARCamera.intrinsics, pixels, sensor orientation
    let sensorResolution: CGSize          // ARCamera.imageResolution, e.g. 1920 x 1440
    let uprightRotation: UprightRotation
    let depth: DepthSnapshot?             // LiDAR phones only
}

enum PlacementMethod: String, Codable {
    case lidarDepth
    case raycastExistingPlane
    case raycastEstimatedPlane
    case planeIntersection
    case fixedDepthFallback
    case manualTap
}

struct AnchoredTarget: Identifiable, Equatable {
    let id: UUID
    let label: String
    let worldPosition: SIMD3<Float>       // meters, ARKit world space
    let placement: PlacementMethod
    let createdAt: Date
}

enum TrackingSummary: Equatable {
    case notStarted
    case initializing
    case normal
    case limited(String)
}

// MARK: - Listener

/// Pose of the phone, ARKit world space.
struct BodyPose: Equatable {
    var position: SIMD3<Float>
    var forward: SIMD3<Float>             // horizontal unit vector, y == 0
}

/// Head rotation relative to the body (from AirPods). Identity = facing the same way as the phone.
struct HeadRotation: Equatable {
    var yawRadians: Float                 // + = head turned LEFT
    var pitchRadians: Float               // + = looking UP

    static let identity = HeadRotation(yawRadians: 0, pitchRadians: 0)
}

/// Where the listener's ears are and which way they face. Fed to the audio engine every frame.
struct ListenerPose: Equatable {
    var position: SIMD3<Float>
    var forward: SIMD3<Float>             // unit
    var up: SIMD3<Float>                  // unit
}

enum ListenerRig: Equatable {
    /// Phone on a stand in front of the user. Ears are behind and above the phone.
    case standInFront(backOffsetMeters: Float, upOffsetMeters: Float)
    /// Phone on the chest. Ears are above the phone.
    case chestMount(upOffsetMeters: Float)
}

enum HeadTrackingStatus: Equatable {
    case unavailable                      // no compatible headphones / API unavailable
    case disconnected
    case connected
    case calibrated
}

// MARK: - Audio

struct CueParameters: Equatable {
    var intervalSeconds: Double           // time between cue pulses
    var gain: Float                       // 0...1
    var isOnTarget: Bool
}

/// Spatialized cue sounds. Files live at Resources/Sounds/<rawValue>.wav, mono.
enum CueSoundID: String, CaseIterable, Codable {
    case primary = "cue_primary"
    case alt1 = "cue_alt1"
    case alt2 = "cue_alt2"
}

/// Non-spatial interface sounds (played centered). Files at Resources/Sounds/<rawValue>.wav.
enum Earcon: String, CaseIterable, Codable {
    case listeningStart = "earcon_listen_start"
    case listeningEnd = "earcon_listen_end"
    case located = "earcon_located"
    case notFound = "earcon_not_found"
    case found = "earcon_found"
}

// MARK: - Study / rounds

enum RoundMode: String, Codable {
    case spokenDirections = "spoken"
    case echora = "echora"
}

struct ActiveRound: Equatable {
    let id: UUID
    let mode: RoundMode
    let objectLabel: String
    let startedAt: Date
}

struct RoundResult: Codable, Identifiable, Equatable {
    let id: UUID
    let participantId: String             // "P01", "P02", ...
    let mode: RoundMode
    let objectLabel: String
    let durationSeconds: Double
    let success: Bool
    let isPractice: Bool
    let headTrackingUsed: Bool
    let placement: PlacementMethod
    let startedAt: Date
    let appVersion: String
}

struct StudyStats: Codable, Equatable {
    let participants: Int                 // completed both modes, non-practice, success
    let echoraRounds: Int
    let spokenRounds: Int
    let medianEchoraSeconds: Double?
    let medianSpokenSeconds: Double?
    let meanEchoraSeconds: Double?
    let meanSpokenSeconds: Double?
    let speedup: Double?                  // medianSpoken / medianEchora
}

/// One sample of how the listener is searching during a round (~10 Hz, both modes).
/// Uploaded with the round when FOUND is tapped. Stored as time-series in Tiger Data.
struct RoundSample: Codable, Equatable {
    let roundId: UUID
    let secondsSinceStart: Double         // since the round timer started
    let mode: RoundMode
    let angleDegrees: Float               // listener forward to target, + = target to the RIGHT
    let distanceMeters: Float             // horizontal, listener to target
    let headYawDegrees: Float             // AirPods yaw, + = head turned LEFT (0 without AirPods)
}

// MARK: - App state

enum EchoraError: Error, Equatable {
    case cameraNotReady
    case trackingLimited(String)
    case objectNotFound(String)
    case locatorTimeout
    case locatorFailed(String)
    case placementFailed
    case audioEngineFailed(String)
    case speechNotAuthorized
    case speechFailed(String)
}

enum EchoraState: Equatable {
    case setup                            // waiting for AR tracking == .normal
    case ready
    case listening
    case locating(utterance: String)
    case guiding(target: AnchoredTarget, round: ActiveRound)
    case narrating(target: AnchoredTarget, round: ActiveRound)
    case found(result: RoundResult)
    case error(EchoraError)
}

struct SystemStatus: Equatable {
    var tracking: TrackingSummary = .notStarted
    var planeDetected: Bool = false
    var headTracking: HeadTrackingStatus = .unavailable
    var backendReachable: Bool = false
    var pendingUploads: Int = 0
}

struct DebugInfo: Equatable {
    var lastUtterance: String?
    var lastDetection: Detection?
    var lastSnapshotJPEG: Data?           // show this with the box drawn on it, NOT the live preview
    var locatorLatencyMs: Int?
    var placement: PlacementMethod?
    var targetPosition: SIMD3<Float>?
    var targetDistanceMeters: Float?
    var targetAngleDegrees: Float?        // + = right
    var cue: CueParameters?
    var headRotation: HeadRotation = .identity
}
```

### 3.2 `Contracts/Protocols.swift`
```swift
import Foundation
import UIKit
import simd

// MARK: - Tisya: perception

protocol PerceptionService: AnyObject {
    /// The camera preview (an ARView under the hood). UI embeds this view.
    var previewView: UIView { get }

    var trackingSummary: TrackingSummary { get }
    var planeDetected: Bool { get }

    /// Called on main at frame rate.
    var onBodyPoseUpdate: ((BodyPose) -> Void)? { get set }
    /// Called on main when tracking state or plane detection changes.
    var onStatusChange: ((TrackingSummary, Bool) -> Void)? { get set }

    func start()
    func pause()

    func currentBodyPose() -> BodyPose?

    /// Copies what we need out of the current ARFrame and releases it.
    func captureSnapshot() throws -> Snapshot

    /// Turns a detection from `snapshot` into a world position using the
    /// camera pose saved in the snapshot (NOT the live camera).
    func place(_ detection: Detection, from snapshot: Snapshot) async throws -> AnchoredTarget

    /// Layer 1: place a target where the operator tapped the preview.
    func placeAtViewPoint(_ point: CGPoint, label: String) throws -> AnchoredTarget

    func showDebugMarker(for target: AnchoredTarget)
    func clearDebugMarkers()
}

protocol ObjectLocator: AnyObject {
    /// One Gemini call. Interprets the request AND finds the object.
    /// Throws EchoraError.objectNotFound, .locatorTimeout, .locatorFailed.
    func locate(utterance: String, in snapshot: Snapshot) async throws -> Detection
}

// MARK: - Seoyeon: head tracking + audio

protocol HeadTracking: AnyObject {
    var status: HeadTrackingStatus { get }
    var onStatusChange: ((HeadTrackingStatus) -> Void)? { get set }

    func start()
    func stop()

    /// "Face the phone now." Current head orientation becomes identity.
    func calibrate()

    /// Returns .identity when unavailable or disconnected. Cheap, call every frame.
    func currentRotation() -> HeadRotation
}

protocol SpatialAudioRendering: AnyObject {
    var isRunning: Bool { get }

    /// Configures AVAudioSession and starts the engine. Audio module is the ONLY
    /// owner of AVAudioSession configuration in the app.
    func start() throws
    func stop()

    func setCueSound(_ id: CueSoundID)
    func setTarget(_ target: AnchoredTarget)
    func clearTarget()

    func updateListener(_ pose: ListenerPose)
    func updateCue(_ parameters: CueParameters)

    func playEarcon(_ earcon: Earcon)
}

// MARK: - Moon: voice, baseline, telemetry

protocol VoiceCommandListening: AnyObject {
    func requestAuthorization() async -> Bool
    /// Push-to-talk press.
    func startListening() throws
    /// Push-to-talk release. Returns the final transcript ("" if nothing heard).
    func stopListening() async -> String
    /// Optional live partial transcript for the UI.
    var onPartialTranscript: ((String) -> Void)? { get set }
}

protocol DirectionsNarrating: AnyObject {
    /// Speaks directions now, then re-speaks updated directions every
    /// `repeatIntervalSeconds` using the latest pose from `poseProvider`.
    func start(
        target: AnchoredTarget,
        repeatIntervalSeconds: Double,
        poseProvider: @escaping () -> BodyPose?
    )
    func repeatNow()
    func stop()
    /// Fires once when the first utterance actually begins (round timer starts here).
    var onFirstUtteranceStarted: (() -> Void)? { get set }
}

protocol TelemetryReporting: AnyObject {
    var pendingCount: Int { get }
    func report(_ result: RoundResult) async
    func fetchStats() async -> StudyStats?
    func ping() async -> Bool
    /// Stretch (v1.5): uploads one finished round's search trajectory.
    func reportSamples(_ samples: [RoundSample]) async
}

extension TelemetryReporting {
    /// Default: drop samples, so implementations without the stretch still conform.
    func reportSamples(_ samples: [RoundSample]) async {
    }
}
```

### 3.3 Pure helper signatures (implemented by the named owner, unit tested)
```swift
// Tisya, Perception/ImageSpace.swift
enum ImageSpace {
    static func sensorNormalized(
        fromUpright point: NormalizedPoint,
        rotation: UprightRotation
    ) -> NormalizedPoint
}

// Tisya, Perception/RayMath.swift
struct Ray: Equatable {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>          // unit
}

enum RayMath {
    static func ray(through uprightPoint: NormalizedPoint, snapshot: Snapshot) -> Ray
    static func point(along ray: Ray, distance: Float) -> SIMD3<Float>
    static func intersectHorizontalPlane(ray: Ray, planeY: Float) -> SIMD3<Float>?

    /// LiDAR path. Samples depth around the point and unprojects to world space.
    /// Returns nil if too few confident samples or depth outside 0.1...3.0 m.
    static func worldPointFromDepth(uprightPoint: NormalizedPoint, snapshot: Snapshot) -> SIMD3<Float>?
}

// Tisya, Perception/Geometry.swift (shared helpers, anyone may CALL them)
enum Geometry {
    static func horizontalForward(fromCameraTransform transform: simd_float4x4) -> SIMD3<Float>?
    /// + = target is to the right of forward. Degrees, -180...180.
    static func signedHorizontalAngleDegrees(
        from position: SIMD3<Float>,
        forward: SIMD3<Float>,
        to target: SIMD3<Float>
    ) -> Float
    static func horizontalDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float
}

// Seoyeon, Audio/ListenerPoseMath.swift
enum ListenerPoseMath {
    static func compose(body: BodyPose, head: HeadRotation, rig: ListenerRig) -> ListenerPose
}

// Seoyeon, Audio/CueModulator.swift
enum CueModulator {
    static func parameters(listener: ListenerPose, target: AnchoredTarget) -> CueParameters
}

// Moon, Voice/DirectionsPhraser.swift
enum DirectionsPhraser {
    static func phrase(label: String, target: SIMD3<Float>, body: BodyPose) -> String
}
```

### 3.4 Mocks (`ios/Echora/Mocks/`, written at scaffold time, owners may improve their own)
- `MockPerceptionService`: `previewView` is a dark gray `UIView` with a label "MOCK CAMERA". Tracking goes `.initializing` then `.normal` after 1 s, `planeDetected = true`. Body pose fixed at origin, forward `(0, 0, -1)`, emitted at 30 Hz via a timer. `captureSnapshot` returns a bundled `mock_table.jpg` (generate any 1024x768 image) with identity transform, plausible intrinsics, and `depth = nil`. `place` returns `(0.2, -0.3, -0.5)` after 50 ms. `placeAtViewPoint` maps x across -0.4...0.4 m.
- `MockObjectLocator`: waits 1.2 s. Returns a box around the image center. Throws `.objectNotFound` if the utterance contains "unicorn" and `.locatorTimeout` if it contains "slow".
- `MockHeadTracker`: status `.connected`; after `calibrate()`, `.calibrated`. Yaw follows a slow sine wave (plus or minus 30 degrees, 6 s period) so UI and audio can be tested.
- `MockSpatialAudio`: logs calls, keeps last listener/target/cue for inspection.
- `MockVoiceListener`: `stopListening` returns "where's my mug".
- `MockDirectionsNarrator`: logs the phrase from `DirectionsPhraser` (or a fixed string before Moon implements it) and calls `onFirstUtteranceStarted` after 300 ms.
- `MockTelemetry`: in-memory, computes `StudyStats` locally.

### 3.5 `App/AppEnvironment.swift`
```swift
struct ServiceFlags {
    var mockPerception: Bool
    var mockLocator: Bool
    var mockHeadTracking: Bool
    var mockAudio: Bool
    var mockVoice: Bool
    var mockNarrator: Bool
    var mockTelemetry: Bool

    static let allMocks = ServiceFlags(
        mockPerception: true,
        mockLocator: true,
        mockHeadTracking: true,
        mockAudio: true,
        mockVoice: true,
        mockNarrator: true,
        mockTelemetry: true
    )
}

@MainActor
final class AppEnvironment {
    let perception: PerceptionService
    let locator: ObjectLocator
    let headTracker: HeadTracking
    let audio: SpatialAudioRendering
    let voice: VoiceCommandListening
    let narrator: DirectionsNarrating
    let telemetry: TelemetryReporting

    static func make(flags: ServiceFlags) -> AppEnvironment { /* pick real or mock per flag */ }
}
```
Flags live in `Config.swift` and can be overridden in the in-app Settings screen. Each person flips only their own piece to real while developing. Until a real implementation exists, its flag is forced to mock.

### 3.6 `App/EchoraCoordinator.swift` (Tisya owns, Qimin's UI binds to it)
```swift
@MainActor
final class EchoraCoordinator: ObservableObject {
    @Published private(set) var state: EchoraState = .setup
    @Published private(set) var status = SystemStatus()
    @Published private(set) var debug = DebugInfo()
    @Published var participantId: String = "P01"
    @Published var mode: RoundMode = .echora
    @Published var isPractice: Bool = false
    @Published var cueSound: CueSoundID = .primary

    init(environment: AppEnvironment)

    // Lifecycle
    func onAppear()
    func onDisappear()

    // Operator intents (the ONLY things UI calls)
    func calibrateHead()                   // optional, debug only: every push-to-talk press already calibrates
    func beginVoiceRequest()               // push-to-talk press (also allowed during a round)
    func endVoiceRequest()                 // push-to-talk release
    func submitTypedRequest(_ text: String)
    func placeTargetAtTap(_ point: CGPoint) // Layer 1 and manual override
    func markFound()
    func cancel()
    func repeatDirections()
    func nextParticipant()                 // P01 -> P02, sets mode for counterbalancing
    func toggleMode()

    // Read-only helpers for UI
    var elapsedSeconds: Double? { get }    // live round timer
    var suggestedFirstMode: RoundMode { get } // odd participant -> spoken, even -> echora
}
```

Coordinator behavior:
- `submitTypedRequest` / `endVoiceRequest`: capture snapshot at that moment, set `.locating`, call locator (timeout from Config), call `place`, show debug marker, play `.located` earcon, then:
  - `.echora`: `audio.setTarget`, start round timer immediately, state `.guiding`.
  - `.spokenDirections`: `narrator.start(...)`, start round timer in `onFirstUtteranceStarted`, state `.narrating`.
- Round timer starts when guidance output begins, so Gemini latency is excluded equally from both modes.
- `markFound`: stop audio target or narrator, play `.found`, build `RoundResult`, `await telemetry.report`, state `.found`.
- Errors: play `.notFound` earcon, state `.error`, auto-return to `.ready` after 2 s. Typed fallback is always available (the hackathon floor will be loud).
- Real-time loop from Part 2.2: audio updates only in `.guiding`; the listener pose is also computed in `.narrating` for sampling. UI debug values throttled to 10 Hz.
- Search trajectory (v1.5): once the round timer has started, in both `.guiding` and `.narrating`, the coordinator records a `RoundSample` every 0.1 s (capped at 5 minutes). `markFound` reports the `RoundResult`, then `telemetry.reportSamples` for that round. Cancelled rounds upload nothing.
- Head calibration is automatic (no button, blind users can't find one):
  - Every `beginVoiceRequest`, `submitTypedRequest`, and a `placeTargetAtTap` that starts a new round recalibrates head tracking first (asking or tapping = facing the phone). A tap during a round only moves the target and does not recalibrate. This also resets AirPods drift on every request.
  - `beginVoiceRequest` is also accepted during a round (`.guiding` / `.narrating`). The press recalibrates; the round, timer and cue keep running. On release: "calibrate" / "recalibrate" / "recenter" / silence -> `.located` earcon, same round continues. An object name -> the round is dropped (no result) and a new request starts.
  - Saying "calibrate" when idle recalibrates without searching.
- FOUND without a button (blind users): during a round, hold push-to-talk and say "found" / "found it" / "got it". The round ends at the **press** time (the user touched the object before pressing; transcription delay is excluded). Said when no round is running, it does nothing (never sent to Gemini). The operator's FOUND button stays for the booth study (most accurate timing).
- Listener direction comes from the AirPods while they are connected: the phone heading is read once at calibration as "straight ahead", then the listener faces that plus the AirPods yaw. The phone's live heading is used only without AirPods.

---

## PART 4. Module specs by owner

### 4.1 Tisya: Perception (`ios/Echora/Perception/`)

Files: `ARSessionController.swift` (implements `PerceptionService`), `SnapshotCapturer.swift`, `ImageSpace.swift`, `RayMath.swift`, `Geometry.swift`, `DebugMarkers.swift`.

Session:
- RealityKit `ARView` with `automaticallyConfigureSession = false`.
- `ARWorldTrackingConfiguration` with `planeDetection = [.horizontal]`. If `ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)`, add `.smoothedSceneDepth` to `frameSemantics` (LiDAR phones, which is our demo phone). Teammates on non-LiDAR phones still run the raycast path, so both paths must work.
- Implement `ARSessionDelegate`. In `session(_:didUpdate:)` read `frame.camera.transform` and `frame.camera.trackingState` only. Never retain `ARFrame` (ARKit stops delivering frames if you hold them).
- Body pose: position = `transform.columns.3.xyz`. Forward = `-transform.columns.2.xyz` projected onto the horizontal plane and normalized. If the horizontal length is below 0.2 (phone pointing straight down), keep the previous forward.
- `planeDetected` = any `ARPlaneAnchor` with `.horizontal` alignment exists.

Snapshot capture:
- `session.currentFrame`, convert `capturedImage` to `CIImage`, rotate to upright for portrait, render with one shared `CIContext`, downscale so the long edge is at most 1024 px, JPEG quality 0.7.
- Copy `camera.transform`, `camera.intrinsics`, `camera.imageResolution`, set `uprightRotation = .portrait`.
- If `frame.smoothedSceneDepth` exists, lock its `depthMap` (Float32) and `confidenceMap` (UInt8) pixel buffers, copy them row by row into `DepthSnapshot` arrays (respect `bytesPerRow`, it can include padding), unlock. About 250 KB, fine.
- Release the frame.

Upright to sensor mapping (the most likely bug in the whole app):
- `ARCamera.transform` and `intrinsics` are in the sensor's landscape orientation regardless of how the phone is held. Gemini sees the upright image. So: upright normalized -> sensor normalized -> sensor pixels.
- Expected portrait mapping: `sensor = (x: upright.y, y: 1 - upright.x)`.
- VERIFY on device with the debug marker test: put one object near the top-left of the preview, request it, see where the red sphere lands. If wrong, try these in order and keep the one that works, then lock it with a unit test:

| Candidate | sensor.x | sensor.y |
|---|---|---|
| A (expected) | upright.y | 1 - upright.x |
| B | 1 - upright.y | upright.x |
| C | upright.y | upright.x |
| D | 1 - upright.y | 1 - upright.x |

Ray math:
```
px = sensor.x * sensorResolution.width
py = sensor.y * sensorResolution.height
fx = intrinsics[0][0], fy = intrinsics[1][1], cx = intrinsics[2][0], cy = intrinsics[2][1]
dirCamera = normalize( ((px - cx) / fx,  -(py - cy) / fy,  -1) )   // image y down, camera y up, camera looks down -Z
dirWorld  = normalize( (cameraTransform * SIMD4(dirCamera, 0)).xyz )
origin    = cameraTransform.columns.3.xyz
```
(simd matrices are column-major: `intrinsics[2][0]` is column 2, row 0, which is cx.)

Placement (`place(_:from:)`):

0. LiDAR first, if `snapshot.depth != nil`. Use `box.center` (the object itself, not its base):
   - Map the upright point to sensor normalized with `ImageSpace`, then to depth pixels: `dx = sensor.x * depth.width`, `dy = sensor.y * depth.height`. The depth map is aligned with `capturedImage`, just lower resolution.
   - Sample a 7x7 patch around (dx, dy). Keep samples with confidence >= 1 (medium) and depth in 0.1...3.0 m. Need at least 8 valid samples, else skip to step 1.
   - Take the 30th percentile, not the median. The object is in front of the table, so the closer values belong to the object. This stops thin objects (keys, pens) from snapping to the table behind them.
   - Unproject with the snapshot intrinsics, using sensor PIXELS `px, py` (intrinsics match `capturedImage`, not the depth map):
     ```
     dirCamera = ((px - cx) / fx, -(py - cy) / fy, -1)    // NOT normalized, z is exactly -1
     pointCamera = dirCamera * depthMeters                  // LiDAR depth is distance along the optical axis
     pointWorld = (cameraTransform * SIMD4(pointCamera, 1)).xyz
     ```
   - Placement `.lidarDepth`. Do not apply `objectCenterLiftMeters` on this path.

Non-LiDAR path (teammates' phones, and fallback when depth is missing), use `box.baseCenter`, not `center`:
1. `ARRaycastQuery(origin:direction:allowing: .existingPlaneGeometry, alignment: .horizontal)` -> `session.raycast(query)`. Hit -> `.raycastExistingPlane`.
2. Else same with `.estimatedPlane`, alignment `.any` -> `.raycastEstimatedPlane`.
3. Else if any horizontal plane anchor exists, `RayMath.intersectHorizontalPlane` at that plane's world Y -> `.planeIntersection`.
4. Else `RayMath.point(along: ray, distance: Config.fallbackDepthMeters)` (0.6 m) -> `.fixedDepthFallback`.
5. On steps 1 to 4 only, raise the final point by `Config.objectCenterLiftMeters` (0.05 m) so the sound sits at the object, not under it.
Building the query from the SAVED snapshot camera is what makes this correct after the phone moves. Do not use `arView.raycast(from: screenPoint)` for detections.

Tap placement (Layer 1): `arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first`. Fallback 0.6 m along the screen ray. Placement `.manualTap`.

Debug marker: red unlit `ModelEntity` sphere, radius 0.02 m, on an `AnchorEntity(world:)` at the target position. Toggle from Settings. This is the single biggest time-saver; build it before Gemini.

Acceptance:
- [x] Layer 1: tap the table, marker appears on the tapped spot, stays there as the phone rotates and moves. (iPhone 14 Pro Max, Fri Oct 9)
- [x] Snapshot captured in under 60 ms. (25-30 ms incl. depth copy on iPhone 14 Pro Max; not measured on an iPhone 13)
- [x] Mapping verified with the corner test, locked with a unit test. (Candidate A; Test mode spheres overlap at all four corners; `ImageSpaceTests`)
- [x] Detection markers land within about 5 cm of real objects on a textured table. (Within arm's reach; small objects ~1 m+ away can be a few cm off)
- [x] On the iPhone Pro, debug panel shows `lidarDepth` for normal objects, and the marker sits on the object itself, including a thin one like keys. (Console `Placed ... via lidarDepth`; Test mode blue sphere on the object)
- [x] Turn LiDAR off in Settings (force `depth = nil`) and confirm the raycast path still works. (Verified with the Test mode green sphere, which runs the same snapshot with `depth = nil`; `debug.disableLiDAR` exists for the Settings toggle)

### 4.2 Tisya: Gemini locator (`ios/Echora/Perception/GeminiLocator.swift`)

- REST: `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`, header `x-goog-api-key: <key>`, `Content-Type: application/json`.
- Models: `Config.geminiModels`, raced as described below (currently `gemini-3.5-flash-lite`, then `gemini-3.1-flash-lite`). Chosen by testing on our key: on the free tier every Flash model is capped at 20 requests/day and Flash Lite at 500/day, with the same box accuracy in testing. Thinking is set to the minimum (`thinkingConfig.thinkingLevel = "minimal"`). `Config.geminiModel` is the first model in the list.
- Body:
```json
{
  "contents": [
    {
      "role": "user",
      "parts": [
        { "inline_data": { "mime_type": "image/jpeg", "data": "<base64 upright JPEG>" } },
        { "text": "<PROMPT>" }
      ]
    }
  ],
  "generationConfig": {
    "temperature": 0,
    "responseMimeType": "application/json",
    "responseSchema": {
      "type": "OBJECT",
      "properties": {
        "found":      { "type": "BOOLEAN" },
        "label":      { "type": "STRING" },
        "box_2d":     { "type": "ARRAY", "items": { "type": "INTEGER" } },
        "confidence": { "type": "NUMBER" },
        "reason":     { "type": "STRING" }
      },
      "required": ["found", "label"]
    }
  }
}
```
- PROMPT:
```
You are the vision module of an object-finding aid for blind users.
The user said: "{utterance}"
1. Decide which single physical object they want.
2. Find that object in the image.
3. If several match, choose the one nearest the camera.
Return JSON only.
box_2d is [ymin, xmin, ymax, xmax], integers normalized to 0-1000, tightly around the object.
If the object is not visible, set found to false, leave box_2d empty, and explain briefly in reason.
```
- Parse `candidates[0].content.parts[0].text` as JSON. Convert box: `minX = xmin/1000`, `minY = ymin/1000`, `maxX = xmax/1000`, `maxY = ymax/1000`. Validate 4 values, min < max, within 0...1, else `.locatorFailed`.
- Hedged requests (v1.7): ask `Config.geminiModels[0]` (`gemini-3.5-flash-lite`) immediately; if it has not answered after `Config.geminiHedgeDelaySeconds` (2.5), or fails with timeout / 503 / 429, ask the next model (`gemini-3.1-flash-lite`) in parallel. The first real answer wins and the other request is cancelled. Real answers (found / not found / malformed / other HTTP errors) end the race. Whole request budget `Config.geminiTimeoutSeconds` (14). A rolling 10-requests-per-minute guard protects the free tier. Log latency, put it in `DebugInfo`.
- Key from Info.plist `GEMINI_API_KEY`, populated from gitignored `Secrets.xcconfig`. A key inside an app binary is extractable; acceptable for a hackathon on our own phones, never ship it. Stretch: proxy through Moon's backend (`POST /api/locate`), not required.
- Unit tests with fixture JSON: found, not found, malformed box, box with values over 1000.

### 4.3 Seoyeon: Head tracking (`ios/Echora/HeadTracking/HeadTracker.swift`)

- `CMHeadphoneMotionManager`. Works with AirPods Pro, AirPods 3rd gen and later, AirPods Max, some Beats. NOT AirPods 1st/2nd gen. Confirm our demo pair first: `isDeviceMotionAvailable` true and motion updates arriving. Requires `NSMotionUsageDescription`.
- `isDeviceMotionAvailable` false -> `.unavailable`. Use `CMHeadphoneMotionManagerDelegate` connect/disconnect callbacks for status.
- `startDeviceMotionUpdates(to: .main)`. Keep the latest `CMAttitude`.
- `calibrate()`: store a copy of the current attitude as reference, status `.calibrated`.
- `currentRotation()`: copy latest attitude, `multiply(byInverseOf: reference)`, extract yaw and pitch, map to our convention (+yaw = LEFT, +pitch = UP). The axis and sign mapping from CoreMotion's headphone frame is easy to get wrong: add a debug readout, turn your head left and confirm yaw goes positive, look up and confirm pitch goes positive, flip signs if not, then hard-code.
- Ignore roll. Clamp pitch to plus or minus 60 degrees.
- Drift: handled automatically, the coordinator recalibrates on every push-to-talk press and typed request (3.6).
- Unavailable or disconnected -> `.identity`. The app must work without AirPods (the user just keeps their head facing forward).

Acceptance:
- [ ] Status flips correctly when AirPods connect, disconnect, are taken out.
- [ ] Head left 45 degrees reads about +0.79 rad yaw. Look up reads positive pitch.
- [ ] Recalibrate zeroes both.

### 4.4 Seoyeon: Spatial audio (`ios/Echora/Audio/`)

Files: `SpatialAudioEngine.swift` (implements `SpatialAudioRendering`), `ListenerPoseMath.swift`, `CueModulator.swift`, `AudioSessionConfigurator.swift`.

Audio session (this module is the only place that configures it):
- Category `.playAndRecord` (speech recognition needs the mic), mode `.default`, options `[.allowBluetoothA2DP, .mixWithOthers]`.
- Do NOT include `.allowBluetooth` (HFP). HFP drops AirPods into low-quality mono call audio and kills spatialization. With A2DP output, the mic input comes from the iPhone's built-in mic, which is what we want.
- Before demos, turn off system "Spatialize Stereo" / Spatial Audio for the AirPods in Control Center so the OS doesn't add its own head tracking on top of ours.

Engine graph:
```
AVAudioPlayerNode (cue, MONO 48 kHz) --> AVAudioEnvironmentNode --> mainMixerNode --> output
AVAudioPlayerNode (earcons, stereo)  ------------------------------> mainMixerNode
```
- Cue player must be connected to the environment node with a mono format, otherwise it will not be spatialized.
- On the cue player: `renderingAlgorithm = .HRTFHQ`, `sourceMode = .pointSource`.
- Environment: `outputType = .headphones`, `distanceAttenuationParameters.distanceAttenuationModel = .inverse`, `referenceDistance = 0.3`, `maximumDistance = 5`, `rolloffFactor = 1.0`. Reverb off.
- `updateListener`: `environment.listenerPosition = AVAudio3DPoint(x,y,z)`, `environment.listenerVectorOrientation = AVAudio3DVectorOrientation(forward: ..., up: ...)`. World coordinates pass through unchanged (same right-handed convention as ARKit).
- `setTarget`: `cuePlayer.position = AVAudio3DPoint(target.worldPosition)`, start pulsing.
- Pulsing: a repeating scheduler that calls `cuePlayer.scheduleBuffer(buffer, at: nil)` every `intervalSeconds`. Adjusting the interval takes effect on the next pulse. A `DispatchSourceTimer` on a dedicated queue is fine.
- Earcons play on the non-spatial player.
- Handle `AVAudioSession.interruptionNotification` and route changes (AirPods removed): restart the engine.

`ListenerPoseMath.compose`:
```
worldUp = (0, 1, 0)
bodyRight = normalize(cross(body.forward, worldUp))
position:
  standInFront(back, up): body.position - body.forward * back + worldUp * up
  chestMount(up):         body.position + worldUp * up
forwardYaw = rotate(body.forward, by: head.yawRadians, around: worldUp)     // + yaw = left
rightYaw   = normalize(cross(forwardYaw, worldUp))
forward    = rotate(forwardYaw, by: head.pitchRadians, around: rightYaw)    // check sign: + pitch must tilt forward UP
up         = normalize(cross(rightYaw, forward))
```
Use `simd_quatf(angle:axis:)` and `act(_:)` for rotations. Unit tests: identity head returns body forward; yaw +90 degrees with body forward `(0,0,-1)` returns `(-1,0,0)`; pitch +30 degrees gives positive forward.y.

`CueModulator.parameters`:
```
angle = abs(Geometry.signedHorizontalAngleDegrees(listener.position, listener.forward, target))
t = clamp(angle / 90, 0, 1)
intervalSeconds = lerp(0.15, 0.70, t)        // faster as you face it
isOnTarget = angle < Config.onTargetThresholdDegrees (12)
gain = 0.9
```
Front/back confusion is a known HRTF weakness. The faster pulse when facing the target is what resolves it, so keep the rate change strong. Tune numbers with blindfolded teammates Friday night.

Acceptance (Layer 1 with Tisya):
- [ ] Wired earphones, eyes closed: the sound clearly comes from the tapped spot.
- [ ] Rotate the phone on its stand 90 degrees: the sound stays on the object, it does not swing with the phone.
- [ ] With AirPods head tracking: turn head left, sound moves to the right ear.
- [ ] No clicks or dropouts over a 5-minute session.

### 4.5 Seoyeon: Voice (`ios/Echora/Voice/VoiceCommandListener.swift`)

- `SFSpeechRecognizer(locale: Locale(identifier: "en-US"))`. If `supportsOnDeviceRecognition`, set `requiresOnDeviceRecognition = true` (faster, works on bad venue Wi-Fi).
- `SFSpeechAudioBufferRecognitionRequest` with `shouldReportPartialResults = true`, `contextualStrings = Config.knownObjects`.
- Uses its own `AVAudioEngine` input tap. Do not configure `AVAudioSession` here (audio module owns it). If two engines fight on device, share one engine (Seoyeon owns both modules now).
- Add "calibrate", "recalibrate", "recenter", "found", "got it" to `contextualStrings` so the voice commands (3.6) are recognized.
- Push-to-talk: `startListening` on press, `stopListening` on release returns the best transcript. Hard stop after 6 s.
- Info.plist: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`.

### 4.6 Moon (DirectionsPhraser) + Seoyeon (DirectionsNarrator): Spoken-directions baseline (`ios/Echora/Voice/`)

Files: `DirectionsPhraser.swift`, `DirectionsNarrator.swift` (implements `DirectionsNarrating`).

The baseline must be genuinely good or judges will call the comparison a strawman. Clock-face directions are the established convention for blind users.
```
angle = Geometry.signedHorizontalAngleDegrees(body.position, body.forward, target)   // + right
hour = Int((angle / 30).rounded())        // 0 = 12 o'clock, +3 = 3 o'clock, -3 = 9 o'clock
hour = ((hour % 12) + 12) % 12; if hour == 0 { hour = 12 }
cm = Int((Geometry.horizontalDistance(body.position, target) * 100 / 10).rounded()) * 10
phrase = "\(label). \(hour) o'clock, about \(cm) centimeters."
```
- Directions are relative to the phone's forward (the user faces the phone). For `standInFront`, measure distance from the user position (phone position minus back offset), not the phone. Ask Tisya for the rig values from `Config`.
- `AVSpeechSynthesizer`, en-US, enhanced voice if installed, rate `AVSpeechUtteranceDefaultSpeechRate`. Fire `onFirstUtteranceStarted` from `speechSynthesizer(_:didStart:)` on the first utterance only.
- Re-speak updated directions every 4 s. `repeatNow()` speaks immediately.
- Unit tests: straight ahead 0.4 m -> "12 o'clock, about 40 centimeters"; directly right -> 3; directly left -> 9; behind -> 6.

### 4.7 Moon: Telemetry client (`ios/Echora/Telemetry/TelemetryClient.swift`)

- `JSONEncoder` with `dateEncodingStrategy = .iso8601`, default camelCase keys. Backend must accept camelCase.
- `POST {Config.backendBaseURL}/api/rounds` with header `X-Echora-Token`.
- On failure, append to `Documents/pending_rounds.json` and retry the queue on the next report, on `ping()` success, and on app launch. Never lose a round.
- `ping()` hits `/health`, coordinator polls every 10 s to update `status.backendReachable`.
- Note: `.xcconfig` treats `//` as a comment, so keep the backend URL in `Config.swift`, not in an xcconfig.
- `reportSamples` (v1.5): `POST {Config.backendBaseURL}/api/rounds/{roundId}/samples` with the `[RoundSample]` array (same encoder, same `X-Echo-Token` header). Same offline queue rule as rounds: never lose a batch.

### 4.8 Moon: Backend (`backend/`)
See Part 5. FastAPI + **Tiger Data** (Tiger Cloud: hosted PostgreSQL with TimescaleDB). Deploy the API to a public host (Render, Railway, or Fly) so venue Wi-Fi client isolation can't break phone-to-laptop traffic. Fallback: run on a laptop behind a Cloudflare tunnel.

Why Tiger Data instead of SQLite: free app hosts often wipe the server disk on restart/redeploy, which would erase a SQLite file mid-weekend; a hosted database survives that. Postgres also has medians built in (`percentile_cont`). It enters us in the MLH "Best Use of Tiger Data" track.

Database plan (verify exact syntax against current Tiger Data docs):
- Connection string in env var `DATABASE_URL` (Tiger Cloud console). Never commit it. Postgres driver: psycopg 3 or asyncpg.
- Table `rounds`: one column per `RoundResult` field (camelCase in SQL to match Swift structs; the API stays camelCase). Make it a hypertable on `startedAt`.
- Idempotency: TimescaleDB requires unique constraints on a hypertable to include the time column, so use `UNIQUE (id, startedAt)` and `INSERT ... ON CONFLICT (id, startedAt) DO NOTHING`; 201 if inserted, 200 if it already existed. Safe because the app always resends the same `startedAt` for a given `id`.
- `/api/stats`: plain SQL. Filter `success = true AND isPractice = false`; medians with `percentile_cont(0.5) WITHIN GROUP (ORDER BY durationSeconds)`; `participants` = distinct `participantId` with a valid round.
- pytest for the stats rules against a throwaway database (a separate Tiger Cloud service or a local TimescaleDB Docker container).
- Dashboard extra: a continuous aggregate (e.g. hourly rounds and mean time per mode) for a "results over the weekend" chart. Medians inside continuous aggregates need the TimescaleDB Toolkit (`percentile_agg`); check it is available on our Tiger Cloud plan, otherwise compute medians live (the data is tiny).

Search trajectories (v1.5, after the core endpoints work): the app uploads each finished round's `RoundSample`s (Part 5). Store them in a hypertable `round_samples(roundId, secondsSinceStart, mode, angleDegrees, distanceMeters, headYawDegrees, receivedAt)`. Dashboard: median |angle| vs time since start; plus per-round metrics such as time until |angle| < 12 degrees and number of overshoots. A continuous aggregate keeps the chart instant. Never on the real-time path: the beeping is computed on the phone.

### 4.9 Moon (build) + Qimin (design): Dashboard (`dashboard/`)
- Static `index.html` + `app.js` + `styles.css`, no build step. Polls `GET /api/stats` and `GET /api/rounds?limit=10` every 3 s.
- Shows: median time with spoken directions, median time with Echora, speedup ("2.4x faster"), number of participants, last 10 rounds, a small footnote "Informal booth testing, not a clinical study."
- Projected on a laptop at the booth. Readable from 3 meters. Our GoDaddy domain points here.

### 4.10 Qimin: iOS UI (`ios/Echora/UI/`)

UI only reads `coordinator.state`, `.status`, `.debug`, published settings, and calls coordinator intents (Part 3.6). It never touches services directly. Develop entirely on `ServiceFlags.allMocks`.

Screens:
1. `OperatorView` (default)
   - Full-bleed camera preview (`PreviewContainer`, wraps `perception.previewView` in a `UIViewRepresentable`). Tap on preview calls `placeTargetAtTap`.
   - Status strip: tracking state, plane found, AirPods status, backend reachable, pending uploads.
   - Participant chip (P07), mode toggle (Echora / Spoken) with the suggested first mode highlighted, practice toggle.
   - Big "Hold to ask" push-to-talk button + text field fallback with quick-pick chips from `Config.knownObjects`. The hold button stays enabled during rounds (holding it recalibrates; saying "calibrate" keeps the round).
   - Live timer during rounds. Huge green FOUND button (reachable one-handed, hard to miss). Cancel. Repeat (spoken mode only). Next participant. No Calibrate button (calibration is automatic, 3.6).
   - Result card after FOUND: time, mode.
2. `DebugPanel` (collapsible sheet): snapshot thumbnail with the detection box drawn on it, utterance, latency, placement method, distance, angle, cue interval, head yaw/pitch as live numbers and a tiny top-down compass showing listener forward and target.
3. `UserModeView`: what a blind user would actually use. One full-screen "hold anywhere to ask" target, haptics (`UIImpactFeedbackGenerator`) on press, release, located, found. Full VoiceOver labels. No information conveyed by visuals alone. Shown in the pitch.
   - The hold target calls `beginVoiceRequest` / `endVoiceRequest` and stays active during a round, so "hold and say *calibrate*" recalibrates and "hold and say *found*" ends the round, without any button.
   - No FOUND button here. Also support **Magic Tap** (two-finger double-tap anywhere, the standard VoiceOver "main action" gesture): during a round it calls `coordinator.markFound()`. In SwiftUI: `.accessibilityAction(.magicTap) { coordinator.markFound() }`.
   - VoiceOver (iOS's built-in screen reader) is how blind users find it: give the target `.accessibilityLabel("Hold anywhere to ask for an object")` and a hint like "Say an object, or say calibrate to recenter the sound".
4. `SettingsView`: mock toggles per service, cue sound picker, rig offsets, debug marker toggle, backend URL display.

Design rules: high contrast, Dynamic Type, minimum 44 pt touch targets, FOUND button at least 88 pt tall. Put colors, type, spacing in `UI/Theme.swift`. Must work in light and dark mode.

Sound design (`ios/Echora/Resources/Sounds/`):
- Cue candidates (`cue_primary`, `cue_alt1`, `cue_alt2`): 80-200 ms, broadband (clicks, wood block, shaker, marimba with a sharp attack, or a short syllable). Pure sine beeps localize badly (the TreeHacks team that tried this learned it the hard way). Mono, 48 kHz, 16-bit WAV, peak around -1 dBFS, no reverb tail.
- Earcons: short, distinct, pleasant. `earcon_not_found` must be clearly different from `earcon_found`.
- Source CC0 sounds or record/make them. Credit sources in `Resources/Sounds/CREDITS.md`.
- Friday night: blindfolded A/B of the three cue candidates with the team. Pick the winner, make it `cue_primary`.

Also Qimin: dashboard visual design, Devpost images, pitch slide (one slide max), demo video storyboard.

---

## PART 5. Backend API contract (Moon)

Base URL: `Config.backendBaseURL`. JSON is camelCase. Dates ISO 8601 UTC. Writes require header `X-Echora-Token: <shared token>`.

| Method | Path | Body | Response |
|---|---|---|---|
| GET | `/health` | none | `{"ok": true}` |
| POST | `/api/rounds` | `RoundResult` | `201 {"id": "..."}`. Idempotent on `id` (re-posting same id returns 200, no duplicate). |
| GET | `/api/rounds?limit=50` | none | `[RoundResult]`, newest first |
| DELETE | `/api/rounds/{id}` | none | `204`. Token required. For junk test rounds. |
| GET | `/api/stats` | none | `StudyStats` |
| POST | `/api/rounds/{id}/samples` | `[RoundSample]` | `201`. Token required. Re-posting the same round replaces its samples (no duplicates). v1.5 stretch. |
| GET | `/api/rounds/{id}/samples` | none | `[RoundSample]` ordered by `secondsSinceStart`. v1.5 stretch. |

`RoundResult` JSON example:
```json
{
  "id": "6F1C2E4A-1B2C-4D5E-8F90-123456789ABC",
  "participantId": "P07",
  "mode": "echora",
  "objectLabel": "blue mug",
  "durationSeconds": 6.42,
  "success": true,
  "isPractice": false,
  "headTrackingUsed": true,
  "placement": "raycastExistingPlane",
  "startedAt": "2026-10-10T18:22:05Z",
  "appVersion": "0.3.0"
}
```

`RoundSample` JSON example (v1.5):
```json
{
  "roundId": "6F1C2E4A-1B2C-4D5E-8F90-123456789ABC",
  "secondsSinceStart": 1.2,
  "mode": "echora",
  "angleDegrees": -14.5,
  "distanceMeters": 0.42,
  "headYawDegrees": 12.0
}
```

Stats rules:
- Exclude `isPractice == true` and `success == false`.
- `participants` = distinct `participantId` with at least one valid round in BOTH modes.
- Medians and means over valid rounds per mode. `speedup = medianSpokenSeconds / medianEchoraSeconds`, null if either side has no data.
- Use medians in the headline (robust to one person who got lost).

Implementation: FastAPI, Tiger Data (hosted PostgreSQL + TimescaleDB, see 4.8), Pydantic models mirroring the Swift structs exactly, CORS open to the dashboard origin, pytest for the stats function. Token and `DATABASE_URL` from env vars.

---

## PART 6. Ownership and collaboration rules

### 6.1 Folder ownership
| Path | Owner |
|---|---|
| `ios/Echora/Contracts/` | Shared, frozen (see 6.3) |
| `ios/Echora/App/` (coordinator, environment, Config) | Tisya |
| `ios/Echora/Perception/` | Tisya |
| `ios/Echora/HeadTracking/` | Seoyeon |
| `ios/Echora/Audio/` | Seoyeon |
| `ios/Echora/Voice/VoiceCommandListener.swift`, `ios/Echora/Voice/DirectionsNarrator.swift` | Seoyeon |
| `ios/Echora/Voice/DirectionsPhraser.swift` | Moon |
| `ios/Echora/Telemetry/` | Moon |
| `ios/Echora/UI/` | Qimin |
| `ios/Echora/Resources/Sounds/` | Qimin |
| `ios/Echora/Mocks/` | Owner of the matching protocol |
| `ios/EchoraTests/` | Each owner adds tests for their own module |
| `backend/` | Moon |
| `dashboard/` | Moon (code), Qimin (design) |
| `project.yml`, `ios/Config/` | Tisya |

### 6.2 Git workflow (GitHub conventions, humans and agents alike)

Every change goes through a branch and a pull request. Nobody commits or pushes directly to `main`.

**1. Start a new branch for every feature**, always from fresh `main`:
```bash
git checkout main
git pull
git checkout -b <name>/<feature>
```
- `<name>` is one of `tisya`, `seoyeon`, `moon`, `qimin`.
- `<feature>` is short kebab-case describing ONE piece of work: `tisya/tap-to-place`, `seoyeon/listener-pose-math`, `moon/backend-stats`, `qimin/operator-view`.
- One feature per branch. When it is merged, the next feature gets a new branch. Do not reuse merged branches.

**2. Commit small, readable commits.**
- Message format: `<area>: <imperative summary>`, e.g. `perception: add tap-to-place raycast`, `audio: pulse cue on DispatchSourceTimer`, `backend: add /api/stats`.
- Only touch folders you own (6.1). Never commit `Secrets.xcconfig`, `Local.xcconfig`, `*.xcodeproj` (generated), `xcuserdata`, `.env`.

**3. Before opening the PR**, bring in the latest `main` and verify:
```bash
git fetch origin
git merge origin/main
xcodegen generate
xcodebuild -scheme Echora -destination 'generic/platform=iOS Simulator' build
xcodebuild -scheme Echora -destination 'platform=iOS Simulator,name=<any installed iPhone>' test
```
`main` must always build and pass tests with all-mocks flags. If your branch lives longer than 2 hours, merge `main` into it at least every 2 hours.

**4. Push and open a pull request into `main`** for every feature:
```bash
git push -u origin <name>/<feature>
gh pr create --base main --fill
```
Fill in the PR template (`.github/pull_request_template.md`): what changed, which CONTRACT part it implements, how it was tested (simulator tests, and on-device steps if device code), and whether `Contracts/` changed.

**5. Merging.**
- The author merges their own PR once build and tests pass, using **squash merge**, then deletes the branch: `gh pr merge --squash --delete-branch`.
- PRs that touch `ios/Echora/Contracts/` need the thumbs up from everyone affected first (6.3).
- PRs that touch `ios/Echora/App/` (coordinator wiring) or `project.yml` need Tisya's review.
- Never force-push to `main`. Never merge someone else's PR without asking them.

**Rules for AI agents (Claude Code etc.):**
- At the start of any task, check the current branch. If it is `main` or a branch for a different feature, create a new `<name>/<feature>` branch from fresh `main` as in step 1 before editing anything.
- Commit on the feature branch, push it, and open the PR with `gh pr create`. Do not push to `main`.
- Do not merge a PR unless the human you are working with explicitly says to.
- Report the PR link to the human when done.

### 6.3 Changing the contract
- Additive changes only during the event (new optional field with a default, new protocol method with a default implementation in an extension).
- Post in the group chat first, wait for a thumbs up from anyone affected, then merge. Add a line to the changelog at the bottom of `docs/CONTRACT.md`.
- Breaking changes need all four people.

---

## PART 7. Project setup

### 7.1 Layout
```
hack-knight-gwh/
  CLAUDE.md
  docs/CONTRACT.md
  project.yml
  .gitignore
  ios/
    Config/
      Base.xcconfig              # committed, #include? "Local.xcconfig" and "Secrets.xcconfig"
      Local.xcconfig.example     # DEVELOPMENT_TEAM, BUNDLE_SUFFIX
      Secrets.xcconfig.example   # GEMINI_API_KEY, ECHORA_BACKEND_TOKEN
    Echora/
      Info.plist
      App/            EchoraApp.swift, EchoraCoordinator.swift, AppEnvironment.swift, Config.swift
      Contracts/      Models.swift, Protocols.swift
      Mocks/          one file per mock
      Perception/     ARSessionController, SnapshotCapturer, ImageSpace, RayMath, Geometry, DebugMarkers, GeminiLocator
      HeadTracking/   HeadTracker
      Audio/          SpatialAudioEngine, AudioSessionConfigurator, ListenerPoseMath, CueModulator
      Voice/          VoiceCommandListener, DirectionsNarrator, DirectionsPhraser
      Telemetry/      TelemetryClient
      UI/             OperatorView, DebugPanel, UserModeView, SettingsView, PreviewContainer, Theme
      Resources/
        Sounds/       cue_*.wav, earcon_*.wav, CREDITS.md
        mock_table.jpg
    EchoraTests/        ImageSpaceTests, RayMathTests, GeometryTests, ListenerPoseMathTests,
                      CueModulatorTests, DirectionsPhraserTests, GeminiParsingTests
  backend/            Moon
  dashboard/          Moon + Qimin
```

### 7.2 XcodeGen (avoids `project.pbxproj` merge conflicts with 4 people)
- Everyone: `brew install xcodegen`. After every pull: `xcodegen generate`. The `.xcodeproj` is gitignored.
- `project.yml` essentials: app target `Echora` (iOS 17.0, sources `ios/Echora`, `SWIFT_VERSION = 5.0`, `PRODUCT_BUNDLE_IDENTIFIER = com.gwh.echora$(BUNDLE_SUFFIX)`, config files `ios/Config/Base.xcconfig`), unit-test target `EchoraTests` depending on `Echora`, scheme `Echora` including tests.
- Signing: each person puts their own `DEVELOPMENT_TEAM` (free personal team is fine) and a `BUNDLE_SUFFIX` like `.tisya` in their gitignored `Local.xcconfig`, so nobody commits signing changes and free-team bundle IDs don't collide.

### 7.3 Info.plist keys
`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `NSMotionUsageDescription`, `UIRequiredDeviceCapabilities: [arkit]`, `GEMINI_API_KEY: $(GEMINI_API_KEY)`, `ECHORA_BACKEND_TOKEN: $(ECHORA_BACKEND_TOKEN)`. Portrait only.

### 7.4 `App/Config.swift` constants
`ios/Echora/App/Config.swift` is the source of truth (Tisya owns it). Snapshot as of Oct 10, for reference:
```swift
enum Config {
    static let geminiModels = ["gemini-3.5-flash-lite", "gemini-3.1-flash-lite"]
    static let geminiModel = geminiModels[0]
    static let geminiThinkingLevel = "minimal"
    static let geminiHedgeDelaySeconds: TimeInterval = 2.5
    static let geminiTimeoutSeconds: TimeInterval = 14
    static let geminiMaxRequestsPerMinute = 10
    static let backendBaseURL = URL(string: "https://SET-ME")!
    static let rig = ListenerRig.standInFront(backOffsetMeters: 0.35, upOffsetMeters: 0.30)
    static let fallbackDepthMeters: Float = 0.6
    static let objectCenterLiftMeters: Float = 0.05
    static let onTargetThresholdDegrees: Float = 12
    static let spokenRepeatIntervalSeconds: Double = 4
    static let knownObjects = [
        "mug", "cup", "bottle", "keys", "phone", "wallet",
        "glasses", "remote", "pen", "headphones", "apple"
    ]
    static let defaultFlags = ServiceFlags.allMocks
    static let appVersion = "0.1.0"
}
```

### 7.5 Placeholder sounds
Generate with a small Python script (`scripts/make_placeholder_sounds.py`, standard library `wave` + `math` + `random`): `cue_*` = 120 ms filtered noise bursts with fast attack, `earcon_*` = short two-tone chirps, all mono 48 kHz 16-bit. Qimin replaces them.

---

## PART 8. Integration plan and checkpoints

| Checkpoint | Target time | Done means |
|---|---|---|
| M0 Contracts | First 45 min | Scaffold merged to `main`, everyone has generated the project and built it on their phone with mocks. |
| M1 Layer 1 (GO/NO-GO) | Friday midnight | Tap-to-place + real spatial audio on device: sound stays on the tapped spot when the phone rotates. Parallel: Moon has backend deployed with `/health` and `/api/rounds`, Qimin has OperatorView running on mocks and 3 cue candidates. |
| M2 Layer 2 | Saturday ~10 AM | Typed request -> Gemini -> marker on the real object -> sound from it. |
| M3 Layer 3-4 | Saturday ~3 PM | Voice requests, spoken baseline, round timing, results reaching the deployed backend. AirPods head tracking in the loop on the demo phone (we have the hardware, so this moves up from M4). |
| M4 Layer 5 | Saturday ~9 PM | Cue modulation tuned with head tracking, dashboard live on our domain, UserModeView done. |
| Freeze | 4 hours before submission | No new features. Pilot with at least 10 people, record a backup demo video, write Devpost. |

**Status (Sat Oct 10, morning):** M1 phone side done Fri ~6 PM (tap-to-place + spatial audio + AirPods head tracking on device); its parallel items (backend `/health` + `/api/rounds`, OperatorView on mocks, cue candidates) still open. M2 done Fri night (typed request -> Gemini -> sphere and sound on the real object, on device).

GO/NO-GO rule: if M1 is not working on a real phone by midnight Friday, we drop to the fixed-depth fallback (direction only) or switch ideas. We do not spend Saturday debugging 3D anchoring.

Integration owner: Tisya merges coordinator wiring. Each owner flips their own flag to real and confirms on device before telling the group "ready."

---

## PART 9. Test plan

Unit tests (simulator, `xcodebuild test`):
- `ImageSpaceTests`: the verified mapping for all four corners.
- `RayMathTests`: identity camera transform, center pixel -> direction `(0, 0, -1)`; pixel right of center -> direction.x > 0; plane intersection at known heights; ray parallel to plane -> nil; `worldPointFromDepth` with a synthetic depth map (object patch at 0.5 m on a 0.8 m background) returns z of about -0.5, and returns nil when confidence is all low.
- `GeometryTests`: angle sign (right is positive), behind is about 180, horizontal distance ignores Y.
- `ListenerPoseMathTests`, `CueModulatorTests`, `DirectionsPhraserTests` as specified above.
- `GeminiParsingTests` with fixtures.
- Backend: pytest for stats (practice excluded, failed excluded, participants need both modes, speedup math).

On-device checklist (run before each checkpoint and before every judging block):
- [ ] Textured surface on the table (placemat, patterned cloth, newspaper). Plain white or glossy tables break plane detection on non-LiDAR phones.
- [ ] Move the phone slowly over the table for about 5 s before mounting it so a plane gets detected; status strip shows "plane found."
- [ ] Good lighting on the table.
- [ ] System Spatialize Stereo off for AirPods. Volume at a comfortable fixed level.
- [ ] Participant faces the phone when they ask (each request calibrates head tracking automatically).
- [ ] Backend reachable, pending uploads 0.
- [ ] Debug markers on for us, hidden for the judge's view if the screen faces them.
- [ ] Spare wired earphones and a charged battery pack.

---

## PART 10. Pitch facts the code must support
- "It doesn't talk": Echora mode plays zero speech.
- Same detection pipeline for both modes, only the output differs. Timer excludes recognition latency in both. This is what makes the comparison fair, say it.
- Report results honestly: "informal booth test, N people, median X s vs Y s."
- Research backing for spatial audio over speech (StereoPilot, IEEE 2022) goes in the Devpost, not in code.

### Changelog
- v1: initial contract.
- v1 scaffold notes (no Contracts/ change): `EchoraCoordinator` also exposes `previewView` (so UI never touches services) and `nonisolated static participantNumber(from:)`. `ServiceFlags.current()` reads per-flag overrides from UserDefaults keys `flag.mockPerception` etc. (Settings screen or launch args). `Audio/ListenerPoseMath.swift` and `Audio/CueModulator.swift` are compile-only stubs for Seoyeon to replace. `UI/OperatorView.swift` and `UI/PreviewContainer.swift` are placeholders for Qimin.
- v1.1: demo hardware is an iPhone Pro (LiDAR) and head-tracking AirPods. Added `DepthSnapshot`, `Snapshot.depth`, `PlacementMethod.lidarDepth`, `RayMath.worldPointFromDepth`, LiDAR-first placement. Non-LiDAR path kept for dev phones.
- v1.1 process: Part 6.2 rewritten. Every feature gets its own `<name>/<feature>` branch from fresh `main` and a pull request; no direct pushes to `main`; squash merge. Agents follow the same rules and never merge without the human saying so. Added `.github/pull_request_template.md`.
- v1.2: no Calibrate button. Head tracking calibrates on every push-to-talk press and typed request; push-to-talk works mid-round and "calibrate" is a voice command. AirPods set listener direction, phone sets position (3.6, 4.3, 4.10, Part 9).
- v1.3: backend database is Tiger Data (hosted PostgreSQL + TimescaleDB) instead of SQLite (4.8, Part 5). API unchanged. Trajectory samples documented as a post-M3 stretch.
- v1.4: rebalanced ownership (Moon + Seoyeon agreed). Seoyeon owns `VoiceCommandListener` and `DirectionsNarrator` (and their mocks); Moon keeps `DirectionsPhraser`, `Telemetry/`, `backend/`, dashboard code (4.5, 4.6, 6.1).
- v1.5 (Moon agreed): search trajectories. Added `RoundSample`, `TelemetryReporting.reportSamples` (default no-op, so existing code still conforms), sampling in 3.6, client rule in 4.7, storage + dashboard plan in 4.8, two endpoints in Part 5.
- v1.6: FOUND without a button: spoken "found" / "got it" ends the round at the push-to-talk press time; UserModeView uses Magic Tap instead of a FOUND button. Operator FOUND button kept for the study (3.6, 4.5, 4.10).
- v1.7: Gemini hedged requests (4.2): `gemini-3.5-flash` first, `gemini-3.6-flash` raced in parallel after 2.5 s or on timeout / 503 / 429; first answer wins; 14 s budget. Found on device: free-tier latency swung between ~1.5 s and 20+ s at random, so sequential timeouts kept failing.
- v1.8: Gemini models switched to Flash Lite (`gemini-3.5-flash-lite`, then `gemini-3.1-flash-lite`): the free tier caps every Flash model at 20 requests/day vs 500/day for Flash Lite, with the same box accuracy in testing.
- Docs refresh (no behavior change): 1.4 current handheld rig, 4.1 acceptance results, 4.2 model wording, 7.4 Config snapshot, Part 8 status.
