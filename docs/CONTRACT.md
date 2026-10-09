# Echo: Build Contract

Repo: https://github.com/tisya05/hack-knight-gwh
Event: Hack Knight 2026, Queens College, Oct 9-11
Team: Tisya (Perception: Gemini + ARKit, integration lead), Seoyeon (Head tracking + spatial audio), Moon (Full stack: backend, dashboard, voice, telemetry, spoken-directions baseline), Qimin (Design, UI/UX, sound design)

This document is the single source of truth for types, protocols, ownership, and conventions. Changes follow Part 6.3.

---

## PART 1. Product spec

### 1.1 One line
Echo helps blind and low-vision people find objects with sound instead of words. You ask for an object, and a sound plays from where that object actually is. Echo does not talk.

### 1.2 The demo we are building toward (about 2 minutes per judge)
1. One-sentence intro, then "try it first."
2. Judge sits at the table, puts on AirPods (or wired earphones) and a disposable sleep mask. We frame it as "testing an audio-only interface," not "experiencing blindness."
3. We place 4 or 5 objects on the table after the mask is on.
4. Round A: judge asks for an object. Spoken-directions mode (clock-face directions, updated every 4 seconds). Timed until they touch it.
5. We move the objects.
6. Round B: judge asks for an object. Echo mode (spatial audio cue only). Timed.
7. Mask off. The booth dashboard shows their two times and the running averages across every visitor this weekend.
8. Mode order alternates per participant (odd IDs: spoken first, even IDs: Echo first) so learning does not bias the result.

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
The phone sits on a small stand or tripod on the table directly in front of the judge, at roughly chest height, back camera facing the table, so the whole tabletop is in frame. The operator (a teammate) sits beside the judge and taps the screen. We are NOT using a chest lanyard as the default because the screen would face the judge's body and the operator could not run rounds. Chest mount stays supported as `ListenerRig.chestMount` in case we need it.

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
EchoCoordinator ---captureSnapshot()---> PerceptionService
   |                                   (copies JPEG + camera transform + intrinsics, releases ARFrame)
   v
ObjectLocator.locate(utterance, snapshot)  --HTTPS-->  Gemini
   |   returns Detection (upright normalized box)
   v
PerceptionService.place(detection, snapshot)
   |   ray from saved camera -> ARKit raycast -> AnchoredTarget (world position, meters)
   v
Mode == .echo:   SpatialAudioRendering.setTarget(target)
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

## PART 3. Shared contract (`ios/Echo/Contracts/`)

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

/// Everything needed to turn a pixel in THIS photo into a 3D ray later,
/// even after the phone has moved. Never store the ARFrame itself.
struct Snapshot {
    let id: UUID
    let capturedAt: Date
    let uprightJPEG: Data                 // sent to Gemini, long edge <= 1024 px
    let cameraTransform: simd_float4x4    // ARCamera.transform at capture time
    let intrinsics: simd_float3x3         // ARCamera.intrinsics, pixels, sensor orientation
    let sensorResolution: CGSize          // ARCamera.imageResolution, e.g. 1920 x 1440
    let uprightRotation: UprightRotation
}

enum PlacementMethod: String, Codable {
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
    case echo = "echo"
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
    let echoRounds: Int
    let spokenRounds: Int
    let medianEchoSeconds: Double?
    let medianSpokenSeconds: Double?
    let meanEchoSeconds: Double?
    let meanSpokenSeconds: Double?
    let speedup: Double?                  // medianSpoken / medianEcho
}

// MARK: - App state

enum EchoError: Error, Equatable {
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

enum EchoState: Equatable {
    case setup                            // waiting for AR tracking == .normal
    case ready
    case listening
    case locating(utterance: String)
    case guiding(target: AnchoredTarget, round: ActiveRound)
    case narrating(target: AnchoredTarget, round: ActiveRound)
    case found(result: RoundResult)
    case error(EchoError)
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
    /// Throws EchoError.objectNotFound, .locatorTimeout, .locatorFailed.
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

### 3.4 Mocks (`ios/Echo/Mocks/`, written at scaffold time, owners may improve their own)
- `MockPerceptionService`: `previewView` is a dark gray `UIView` with a label "MOCK CAMERA". Tracking goes `.initializing` then `.normal` after 1 s, `planeDetected = true`. Body pose fixed at origin, forward `(0, 0, -1)`, emitted at 30 Hz via a timer. `captureSnapshot` returns a bundled `mock_table.jpg` (generate any 1024x768 image) with identity transform and plausible intrinsics. `place` returns `(0.2, -0.3, -0.5)` after 50 ms. `placeAtViewPoint` maps x across -0.4...0.4 m.
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

### 3.6 `App/EchoCoordinator.swift` (Tisya owns, Qimin's UI binds to it)
```swift
@MainActor
final class EchoCoordinator: ObservableObject {
    @Published private(set) var state: EchoState = .setup
    @Published private(set) var status = SystemStatus()
    @Published private(set) var debug = DebugInfo()
    @Published var participantId: String = "P01"
    @Published var mode: RoundMode = .echo
    @Published var isPractice: Bool = false
    @Published var cueSound: CueSoundID = .primary

    init(environment: AppEnvironment)

    // Lifecycle
    func onAppear()
    func onDisappear()

    // Operator intents (the ONLY things UI calls)
    func calibrateHead()
    func beginVoiceRequest()               // push-to-talk press
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
    var suggestedFirstMode: RoundMode { get } // odd participant -> spoken, even -> echo
}
```

Coordinator behavior:
- `submitTypedRequest` / `endVoiceRequest`: capture snapshot at that moment, set `.locating`, call locator (timeout from Config), call `place`, show debug marker, play `.located` earcon, then:
  - `.echo`: `audio.setTarget`, start round timer immediately, state `.guiding`.
  - `.spokenDirections`: `narrator.start(...)`, start round timer in `onFirstUtteranceStarted`, state `.narrating`.
- Round timer starts when guidance output begins, so Gemini latency is excluded equally from both modes.
- `markFound`: stop audio target or narrator, play `.found`, build `RoundResult`, `await telemetry.report`, state `.found`.
- Errors: play `.notFound` earcon, state `.error`, auto-return to `.ready` after 2 s. Typed fallback is always available (the hackathon floor will be loud).
- Real-time loop from Part 2.2 runs only in `.guiding`. UI debug values throttled to 10 Hz.

---

## PART 4. Module specs by owner

### 4.1 Tisya: Perception (`ios/Echo/Perception/`)

Files: `ARSessionController.swift` (implements `PerceptionService`), `SnapshotCapturer.swift`, `ImageSpace.swift`, `RayMath.swift`, `Geometry.swift`, `DebugMarkers.swift`.

Session:
- RealityKit `ARView` with `automaticallyConfigureSession = false`.
- `ARWorldTrackingConfiguration` with `planeDetection = [.horizontal]`. If `ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)`, enable it (LiDAR phones only, optional).
- Implement `ARSessionDelegate`. In `session(_:didUpdate:)` read `frame.camera.transform` and `frame.camera.trackingState` only. Never retain `ARFrame` (ARKit stops delivering frames if you hold them).
- Body pose: position = `transform.columns.3.xyz`. Forward = `-transform.columns.2.xyz` projected onto the horizontal plane and normalized. If the horizontal length is below 0.2 (phone pointing straight down), keep the previous forward.
- `planeDetected` = any `ARPlaneAnchor` with `.horizontal` alignment exists.

Snapshot capture:
- `session.currentFrame`, convert `capturedImage` to `CIImage`, rotate to upright for portrait, render with one shared `CIContext`, downscale so the long edge is at most 1024 px, JPEG quality 0.7.
- Copy `camera.transform`, `camera.intrinsics`, `camera.imageResolution`, set `uprightRotation = .portrait`. Release the frame.

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

Placement (`place(_:from:)`), use `box.baseCenter`, not `center`:
1. `ARRaycastQuery(origin:direction:allowing: .existingPlaneGeometry, alignment: .horizontal)` -> `session.raycast(query)`. Hit -> `.raycastExistingPlane`.
2. Else same with `.estimatedPlane`, alignment `.any` -> `.raycastEstimatedPlane`.
3. Else if any horizontal plane anchor exists, `RayMath.intersectHorizontalPlane` at that plane's world Y -> `.planeIntersection`.
4. Else `RayMath.point(along: ray, distance: Config.fallbackDepthMeters)` (0.6 m) -> `.fixedDepthFallback`.
5. Raise the final point by `Config.objectCenterLiftMeters` (0.05 m) so the sound sits at the object, not under it.
Building the query from the SAVED snapshot camera is what makes this correct after the phone moves. Do not use `arView.raycast(from: screenPoint)` for detections.

Tap placement (Layer 1): `arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first`. Fallback 0.6 m along the screen ray. Placement `.manualTap`.

Debug marker: red unlit `ModelEntity` sphere, radius 0.02 m, on an `AnchorEntity(world:)` at the target position. Toggle from Settings. This is the single biggest time-saver; build it before Gemini.

Acceptance:
- [ ] Layer 1: tap the table, marker appears on the tapped spot, stays there as the phone rotates and moves.
- [ ] Snapshot captured in under 60 ms on iPhone 13.
- [ ] Mapping verified with the corner test, locked with a unit test.
- [ ] Detection markers land within about 5 cm of real objects on a textured table.

### 4.2 Tisya: Gemini locator (`ios/Echo/Perception/GeminiLocator.swift`)

- REST: `POST https://generativelanguage.googleapis.com/v1beta/models/{Config.geminiModel}:generateContent`, header `x-goog-api-key: <key>`, `Content-Type: application/json`.
- `Config.geminiModel`: set to the newest Flash model available on our key (check ai.google.dev model list at the start; Flash for latency). If the model supports a thinking setting, set it to the minimum.
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
- `URLSession` with `timeoutInterval = Config.geminiTimeoutSeconds` (8). No automatic retry. Log latency, put it in `DebugInfo`.
- Key from Info.plist `GEMINI_API_KEY`, populated from gitignored `Secrets.xcconfig`. A key inside an app binary is extractable; acceptable for a hackathon on our own phones, never ship it. Stretch: proxy through Moon's backend (`POST /api/locate`), not required.
- Unit tests with fixture JSON: found, not found, malformed box, box with values over 1000.

### 4.3 Seoyeon: Head tracking (`ios/Echo/HeadTracking/HeadTracker.swift`)

- `CMHeadphoneMotionManager`. Works with AirPods Pro, AirPods 3rd gen and later, AirPods Max, some Beats. Requires `NSMotionUsageDescription`.
- `isDeviceMotionAvailable` false -> `.unavailable`. Use `CMHeadphoneMotionManagerDelegate` connect/disconnect callbacks for status.
- `startDeviceMotionUpdates(to: .main)`. Keep the latest `CMAttitude`.
- `calibrate()`: store a copy of the current attitude as reference, status `.calibrated`.
- `currentRotation()`: copy latest attitude, `multiply(byInverseOf: reference)`, extract yaw and pitch, map to our convention (+yaw = LEFT, +pitch = UP). The axis and sign mapping from CoreMotion's headphone frame is easy to get wrong: add a debug readout, turn your head left and confirm yaw goes positive, look up and confirm pitch goes positive, flip signs if not, then hard-code.
- Ignore roll. Clamp pitch to plus or minus 60 degrees.
- Drift: the operator recalibrates per participant ("face the phone").
- Unavailable or disconnected -> `.identity`. The app must work without AirPods (the user just keeps their head facing forward).

Acceptance:
- [ ] Status flips correctly when AirPods connect, disconnect, are taken out.
- [ ] Head left 45 degrees reads about +0.79 rad yaw. Look up reads positive pitch.
- [ ] Recalibrate zeroes both.

### 4.4 Seoyeon: Spatial audio (`ios/Echo/Audio/`)

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

### 4.5 Moon: Voice (`ios/Echo/Voice/VoiceCommandListener.swift`)

- `SFSpeechRecognizer(locale: Locale(identifier: "en-US"))`. If `supportsOnDeviceRecognition`, set `requiresOnDeviceRecognition = true` (faster, works on bad venue Wi-Fi).
- `SFSpeechAudioBufferRecognitionRequest` with `shouldReportPartialResults = true`, `contextualStrings = Config.knownObjects`.
- Uses its own `AVAudioEngine` input tap. Do not configure `AVAudioSession` here (audio module owns it). If two engines fight on device, tell Seoyeon and Tisya immediately; the fix is to share one engine.
- Push-to-talk: `startListening` on press, `stopListening` on release returns the best transcript. Hard stop after 6 s.
- Info.plist: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`.

### 4.6 Moon: Spoken-directions baseline (`ios/Echo/Voice/`)

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

### 4.7 Moon: Telemetry client (`ios/Echo/Telemetry/TelemetryClient.swift`)

- `JSONEncoder` with `dateEncodingStrategy = .iso8601`, default camelCase keys. Backend must accept camelCase.
- `POST {Config.backendBaseURL}/api/rounds` with header `X-Echo-Token`.
- On failure, append to `Documents/pending_rounds.json` and retry the queue on the next report, on `ping()` success, and on app launch. Never lose a round.
- `ping()` hits `/health`, coordinator polls every 10 s to update `status.backendReachable`.
- Note: `.xcconfig` treats `//` as a comment, so keep the backend URL in `Config.swift`, not in an xcconfig.

### 4.8 Moon: Backend (`backend/`)
See Part 5. FastAPI + SQLite. Deploy to a public host (Render, Railway, or Fly) so venue Wi-Fi client isolation can't break phone-to-laptop traffic. Fallback: run on a laptop behind a Cloudflare tunnel.

### 4.9 Moon (build) + Qimin (design): Dashboard (`dashboard/`)
- Static `index.html` + `app.js` + `styles.css`, no build step. Polls `GET /api/stats` and `GET /api/rounds?limit=10` every 3 s.
- Shows: median time with spoken directions, median time with Echo, speedup ("2.4x faster"), number of participants, last 10 rounds, a small footnote "Informal booth testing, not a clinical study."
- Projected on a laptop at the booth. Readable from 3 meters. Our GoDaddy domain points here.

### 4.10 Qimin: iOS UI (`ios/Echo/UI/`)

UI only reads `coordinator.state`, `.status`, `.debug`, published settings, and calls coordinator intents (Part 3.6). It never touches services directly. Develop entirely on `ServiceFlags.allMocks`.

Screens:
1. `OperatorView` (default)
   - Full-bleed camera preview (`PreviewContainer`, wraps `perception.previewView` in a `UIViewRepresentable`). Tap on preview calls `placeTargetAtTap`.
   - Status strip: tracking state, plane found, AirPods status, backend reachable, pending uploads.
   - Participant chip (P07), mode toggle (Echo / Spoken) with the suggested first mode highlighted, practice toggle.
   - Big "Hold to ask" push-to-talk button + text field fallback with quick-pick chips from `Config.knownObjects`.
   - Live timer during rounds. Huge green FOUND button (reachable one-handed, hard to miss). Cancel. Repeat (spoken mode only). Calibrate head. Next participant.
   - Result card after FOUND: time, mode.
2. `DebugPanel` (collapsible sheet): snapshot thumbnail with the detection box drawn on it, utterance, latency, placement method, distance, angle, cue interval, head yaw/pitch as live numbers and a tiny top-down compass showing listener forward and target.
3. `UserModeView`: what a blind user would actually use. One full-screen "hold anywhere to ask" target, haptics (`UIImpactFeedbackGenerator`) on press, release, located, found. Full VoiceOver labels. No information conveyed by visuals alone. Shown in the pitch.
4. `SettingsView`: mock toggles per service, cue sound picker, rig offsets, debug marker toggle, backend URL display.

Design rules: high contrast, Dynamic Type, minimum 44 pt touch targets, FOUND button at least 88 pt tall. Put colors, type, spacing in `UI/Theme.swift`. Must work in light and dark mode.

Sound design (`ios/Echo/Resources/Sounds/`):
- Cue candidates (`cue_primary`, `cue_alt1`, `cue_alt2`): 80-200 ms, broadband (clicks, wood block, shaker, marimba with a sharp attack, or a short syllable). Pure sine beeps localize badly (the TreeHacks team that tried this learned it the hard way). Mono, 48 kHz, 16-bit WAV, peak around -1 dBFS, no reverb tail.
- Earcons: short, distinct, pleasant. `earcon_not_found` must be clearly different from `earcon_found`.
- Source CC0 sounds or record/make them. Credit sources in `Resources/Sounds/CREDITS.md`.
- Friday night: blindfolded A/B of the three cue candidates with the team. Pick the winner, make it `cue_primary`.

Also Qimin: dashboard visual design, Devpost images, pitch slide (one slide max), demo video storyboard.

---

## PART 5. Backend API contract (Moon)

Base URL: `Config.backendBaseURL`. JSON is camelCase. Dates ISO 8601 UTC. Writes require header `X-Echo-Token: <shared token>`.

| Method | Path | Body | Response |
|---|---|---|---|
| GET | `/health` | none | `{"ok": true}` |
| POST | `/api/rounds` | `RoundResult` | `201 {"id": "..."}`. Idempotent on `id` (re-posting same id returns 200, no duplicate). |
| GET | `/api/rounds?limit=50` | none | `[RoundResult]`, newest first |
| DELETE | `/api/rounds/{id}` | none | `204`. Token required. For junk test rounds. |
| GET | `/api/stats` | none | `StudyStats` |

`RoundResult` JSON example:
```json
{
  "id": "6F1C2E4A-1B2C-4D5E-8F90-123456789ABC",
  "participantId": "P07",
  "mode": "echo",
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

Stats rules:
- Exclude `isPractice == true` and `success == false`.
- `participants` = distinct `participantId` with at least one valid round in BOTH modes.
- Medians and means over valid rounds per mode. `speedup = medianSpokenSeconds / medianEchoSeconds`, null if either side has no data.
- Use medians in the headline (robust to one person who got lost).

Implementation: FastAPI, SQLite file, Pydantic models mirroring the Swift structs exactly, CORS open to the dashboard origin, pytest for the stats function. Token from an env var.

---

## PART 6. Ownership and collaboration rules

### 6.1 Folder ownership
| Path | Owner |
|---|---|
| `ios/Echo/Contracts/` | Shared, frozen (see 6.3) |
| `ios/Echo/App/` (coordinator, environment, Config) | Tisya |
| `ios/Echo/Perception/` | Tisya |
| `ios/Echo/HeadTracking/` | Seoyeon |
| `ios/Echo/Audio/` | Seoyeon |
| `ios/Echo/Voice/` | Moon |
| `ios/Echo/Telemetry/` | Moon |
| `ios/Echo/UI/` | Qimin |
| `ios/Echo/Resources/Sounds/` | Qimin |
| `ios/Echo/Mocks/` | Owner of the matching protocol |
| `ios/EchoTests/` | Each owner adds tests for their own module |
| `backend/` | Moon |
| `dashboard/` | Moon (code), Qimin (design) |
| `project.yml`, `ios/Config/` | Tisya |

### 6.2 Git workflow
- Branches: `tisya/...`, `seoyeon/...`, `moon/...`, `qimin/...`.
- `main` must always build with all-mocks flags. Pull `main` into your branch at least every 2 hours.
- Merge small and often. Before merging: `xcodegen generate`, build, run unit tests.
- Never commit: `Secrets.xcconfig`, `Local.xcconfig`, `*.xcodeproj` (generated), `xcuserdata`, `.env`.

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
      Secrets.xcconfig.example   # GEMINI_API_KEY, ECHO_BACKEND_TOKEN
    Echo/
      Info.plist
      App/            EchoApp.swift, EchoCoordinator.swift, AppEnvironment.swift, Config.swift
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
    EchoTests/        ImageSpaceTests, RayMathTests, GeometryTests, ListenerPoseMathTests,
                      CueModulatorTests, DirectionsPhraserTests, GeminiParsingTests
  backend/            Moon
  dashboard/          Moon + Qimin
```

### 7.2 XcodeGen (avoids `project.pbxproj` merge conflicts with 4 people)
- Everyone: `brew install xcodegen`. After every pull: `xcodegen generate`. The `.xcodeproj` is gitignored.
- `project.yml` essentials: app target `Echo` (iOS 17.0, sources `ios/Echo`, `SWIFT_VERSION = 5.0`, `PRODUCT_BUNDLE_IDENTIFIER = com.gwh.echo$(BUNDLE_SUFFIX)`, config files `ios/Config/Base.xcconfig`), unit-test target `EchoTests` depending on `Echo`, scheme `Echo` including tests.
- Signing: each person puts their own `DEVELOPMENT_TEAM` (free personal team is fine) and a `BUNDLE_SUFFIX` like `.tisya` in their gitignored `Local.xcconfig`, so nobody commits signing changes and free-team bundle IDs don't collide.

### 7.3 Info.plist keys
`NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `NSMotionUsageDescription`, `UIRequiredDeviceCapabilities: [arkit]`, `GEMINI_API_KEY: $(GEMINI_API_KEY)`, `ECHO_BACKEND_TOKEN: $(ECHO_BACKEND_TOKEN)`. Portrait only.

### 7.4 `App/Config.swift` constants
```swift
enum Config {
    static let geminiModel = "SET-ME-newest-flash-model"
    static let geminiTimeoutSeconds: TimeInterval = 8
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
| M3 Layer 3-4 | Saturday ~3 PM | Voice requests, spoken baseline, round timing, results reaching the deployed backend. |
| M4 Layer 5 | Saturday ~9 PM | AirPods head tracking in the loop, cue modulation tuned, dashboard live on our domain, UserModeView done. |
| Freeze | 4 hours before submission | No new features. Pilot with at least 10 people, record a backup demo video, write Devpost. |

GO/NO-GO rule: if M1 is not working on a real phone by midnight Friday, we drop to the fixed-depth fallback (direction only) or switch ideas. We do not spend Saturday debugging 3D anchoring.

Integration owner: Tisya merges coordinator wiring. Each owner flips their own flag to real and confirms on device before telling the group "ready."

---

## PART 9. Test plan

Unit tests (simulator, `xcodebuild test`):
- `ImageSpaceTests`: the verified mapping for all four corners.
- `RayMathTests`: identity camera transform, center pixel -> direction `(0, 0, -1)`; pixel right of center -> direction.x > 0; plane intersection at known heights; ray parallel to plane -> nil.
- `GeometryTests`: angle sign (right is positive), behind is about 180, horizontal distance ignores Y.
- `ListenerPoseMathTests`, `CueModulatorTests`, `DirectionsPhraserTests` as specified above.
- `GeminiParsingTests` with fixtures.
- Backend: pytest for stats (practice excluded, failed excluded, participants need both modes, speedup math).

On-device checklist (run before each checkpoint and before every judging block):
- [ ] Textured surface on the table (placemat, patterned cloth, newspaper). Plain white or glossy tables break plane detection on non-LiDAR phones.
- [ ] Move the phone slowly over the table for about 5 s before mounting it so a plane gets detected; status strip shows "plane found."
- [ ] Good lighting on the table.
- [ ] System Spatialize Stereo off for AirPods. Volume at a comfortable fixed level.
- [ ] Head calibrated with the participant facing the phone.
- [ ] Backend reachable, pending uploads 0.
- [ ] Debug markers on for us, hidden for the judge's view if the screen faces them.
- [ ] Spare wired earphones and a charged battery pack.

---

## PART 10. Pitch facts the code must support
- "It doesn't talk": Echo mode plays zero speech.
- Same detection pipeline for both modes, only the output differs. Timer excludes recognition latency in both. This is what makes the comparison fair, say it.
- Report results honestly: "informal booth test, N people, median X s vs Y s."
- Research backing for spatial audio over speech (StereoPilot, IEEE 2022) goes in the Devpost, not in code.

### Changelog
- v1: initial contract.
- v1 scaffold notes (no Contracts/ change): `EchoCoordinator` also exposes `previewView` (so UI never touches services) and `nonisolated static participantNumber(from:)`. `ServiceFlags.current()` reads per-flag overrides from UserDefaults keys `flag.mockPerception` etc. (Settings screen or launch args). `Audio/ListenerPoseMath.swift` and `Audio/CueModulator.swift` are compile-only stubs for Seoyeon to replace. `UI/OperatorView.swift` and `UI/PreviewContainer.swift` are placeholders for Qimin.
