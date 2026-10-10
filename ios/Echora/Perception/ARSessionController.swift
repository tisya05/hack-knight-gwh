import Foundation
import ARKit
import RealityKit
import UIKit
import os

/// Real `PerceptionService`: RealityKit ARView + ARKit world tracking.
/// Device only. AppEnvironment falls back to the mock when ARKit is unsupported (simulator).
///
/// Layer 1: session, body pose, tap-to-place, debug markers.
/// Layer 2: snapshot capture and detection placement (LiDAR first, then raycasts from
/// the SAVED snapshot camera, plane intersection, fixed depth).
///
/// Device test without Gemini: LONG-PRESS the preview. The pressed point goes through
/// the full photo pipeline and is compared with a direct screen raycast:
/// red = direct, blue = LiDAR path, green = non-LiDAR path; offsets shown in the readout.
final class ARSessionController: NSObject, PerceptionService, ARSessionDelegate, UIGestureRecognizerDelegate {
    let previewView: UIView
    private(set) var trackingSummary: TrackingSummary = .notStarted
    private(set) var planeDetected = false

    var onBodyPoseUpdate: ((BodyPose) -> Void)?
    var onStatusChange: ((TrackingSummary, Bool) -> Void)?

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    /// UserDefaults key: true forces `depth = nil` in snapshots (test the non-LiDAR path).
    static let disableLiDARKey = "debug.disableLiDAR"

    private let arView: ARView
    private let debugMarkers: DebugMarkers
    private let snapshotCapturer = SnapshotCapturer()
    private let debugLabel = UILabel()
    private let logger = Logger(subsystem: "com.gwh.echora", category: "Perception")

    private var latestBodyPose: BodyPose?
    private var lastForward = SIMD3<Float>(0, 0, -1)
    /// World Y of every horizontal plane ARKit has found, for plane intersection.
    private var horizontalPlaneHeights: [UUID: Float] = [:]
    private var hasStartedOnce = false
    private var usesLiDAR = false

    /// Targets whose tap raycast missed and fell back to fixed depth. Drawn yellow instead of red.
    private var fallbackTargetIDs = Set<UUID>()
    private var lastTapDescription = "none"
    private var lastDetectDescription = "long-press to test"

    override init() {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        arView = view
        previewView = view
        debugMarkers = DebugMarkers(arView: view)
        super.init()

        view.session.delegate = self
        installDebugLabel()
        installDetectionTestGesture()
    }

    // MARK: - Lifecycle

    func start() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]

        usesLiDAR = ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
        if usesLiDAR {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }

        var options: ARSession.RunOptions = []
        if !hasStartedOnce {
            options = [.resetTracking, .removeExistingAnchors]
            hasStartedOnce = true
        }

        logger.info("Starting AR session, LiDAR depth: \(self.usesLiDAR, privacy: .public)")
        arView.session.run(configuration, options: options)
        setStatus(tracking: .initializing, planeDetected: planeDetected)
    }

    func pause() {
        logger.info("Pausing AR session")
        arView.session.pause()
    }

    func currentBodyPose() -> BodyPose? {
        return latestBodyPose
    }

    // MARK: - Layer 2: snapshot capture

    func captureSnapshot() throws -> Snapshot {
        if case .limited(let reason) = trackingSummary {
            throw EchoraError.trackingLimited(reason)
        }
        guard let frame = arView.session.currentFrame else {
            throw EchoraError.cameraNotReady
        }
        let includeDepth = !UserDefaults.standard.bool(forKey: Self.disableLiDARKey)
        return try snapshotCapturer.capture(from: frame, includeDepth: includeDepth)
    }

    // MARK: - Layer 2: detection placement

    func place(_ detection: Detection, from snapshot: Snapshot) async throws -> AnchoredTarget {
        let placed = locate(detection.box, in: snapshot)

        var position = placed.position
        if placed.method != .lidarDepth {
            // Raycast / plane / fixed-depth points sit on the table: lift to the object.
            position.y += Config.objectCenterLiftMeters
        }

        logger.info("Placed \(detection.label, privacy: .public) via \(placed.method.rawValue, privacy: .public) at \(Self.format(position), privacy: .public)")

        return AnchoredTarget(
            id: UUID(),
            label: detection.label,
            worldPosition: position,
            placement: placed.method,
            createdAt: Date()
        )
    }

    /// CONTRACT 4.1 placement order, WITHOUT the object-center lift.
    /// Everything is built from the SAVED snapshot camera, never the live camera.
    private func locate(_ box: NormalizedRect, in snapshot: Snapshot) -> (position: SIMD3<Float>, method: PlacementMethod) {
        // 0. LiDAR: the object itself, so use its center.
        if let lidarPoint = RayMath.worldPointFromDepth(uprightPoint: box.center, snapshot: snapshot) {
            return (lidarPoint, .lidarDepth)
        }

        // 1-4. Non-LiDAR: where the object meets the table, so use its base.
        let ray = RayMath.ray(through: box.baseCenter, snapshot: snapshot)

        if let hit = raycast(ray, allowing: .existingPlaneGeometry, alignment: .horizontal) {
            return (hit, .raycastExistingPlane)
        }
        if let hit = raycast(ray, allowing: .estimatedPlane, alignment: .any) {
            return (hit, .raycastEstimatedPlane)
        }
        if let hit = nearestPlaneIntersection(ray) {
            return (hit, .planeIntersection)
        }
        let fallback = RayMath.point(along: ray, distance: Config.fallbackDepthMeters)
        return (fallback, .fixedDepthFallback)
    }

    private func raycast(
        _ ray: Ray,
        allowing target: ARRaycastQuery.Target,
        alignment: ARRaycastQuery.TargetAlignment
    ) -> SIMD3<Float>? {
        let query = ARRaycastQuery(
            origin: ray.origin,
            direction: ray.direction,
            allowing: target,
            alignment: alignment
        )
        let results = arView.session.raycast(query)
        guard let first = results.first else {
            return nil
        }
        return Self.translation(of: first.worldTransform)
    }

    private func nearestPlaneIntersection(_ ray: Ray) -> SIMD3<Float>? {
        var best: SIMD3<Float>?
        var bestDistance = Float.greatestFiniteMagnitude
        for planeY in horizontalPlaneHeights.values {
            guard let hit = RayMath.intersectHorizontalPlane(ray: ray, planeY: planeY) else {
                continue
            }
            let distance = simd_distance(ray.origin, hit)
            if distance < bestDistance {
                bestDistance = distance
                best = hit
            }
        }
        return best
    }

    // MARK: - Layer 1: tap to place

    func placeAtViewPoint(_ point: CGPoint, label: String) throws -> AnchoredTarget {
        let worldPosition: SIMD3<Float>
        var usedFallback = false

        let hits = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any)
        if let hit = hits.first {
            worldPosition = Self.translation(of: hit.worldTransform)
        } else {
            guard let screenRay = arView.ray(through: point) else {
                logger.error("Tap at \(String(describing: point), privacy: .public): no raycast hit and no screen ray")
                throw EchoraError.placementFailed
            }
            let ray = Ray(
                origin: screenRay.origin,
                direction: simd_normalize(screenRay.direction)
            )
            worldPosition = RayMath.point(along: ray, distance: Config.fallbackDepthMeters)
            usedFallback = true
        }

        let target = AnchoredTarget(
            id: UUID(),
            label: label,
            worldPosition: worldPosition,
            placement: .manualTap,
            createdAt: Date()
        )

        if usedFallback {
            fallbackTargetIDs.insert(target.id)
        }

        let method = usedFallback ? "fallback 0.6 m" : "raycast"
        lastTapDescription = "\(method) \(Self.format(worldPosition))"
        logger.info("Tap at \(String(describing: point), privacy: .public) -> \(self.lastTapDescription, privacy: .public)")
        refreshDebugLabel()

        return target
    }

    func showDebugMarker(for target: AnchoredTarget) {
        var color = UIColor.red
        if fallbackTargetIDs.contains(target.id) {
            color = UIColor.yellow
        }
        debugMarkers.show(at: target.worldPosition, color: color)
    }

    func clearDebugMarkers() {
        debugMarkers.clear()
    }

    // MARK: - ARSessionDelegate (called on main)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Read only what we need. Never keep a reference to `frame`.
        let transform = frame.camera.transform
        let trackingState = frame.camera.trackingState

        let pose = Self.bodyPose(fromCameraTransform: transform, previousForward: lastForward)
        lastForward = pose.forward
        latestBodyPose = pose
        onBodyPoseUpdate?(pose)

        let summary = Self.summary(from: trackingState)
        if summary != trackingSummary {
            logger.info("Tracking: \(String(describing: summary), privacy: .public)")
            setStatus(tracking: summary, planeDetected: planeDetected)
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        updatePlanes(addedOrUpdated: anchors, removed: [])
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        updatePlanes(addedOrUpdated: anchors, removed: [])
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        updatePlanes(addedOrUpdated: [], removed: anchors)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        logger.error("AR session failed: \(error.localizedDescription, privacy: .public)")
        setStatus(tracking: .limited("Session failed"), planeDetected: planeDetected)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        logger.warning("AR session interrupted")
        setStatus(tracking: .limited("Interrupted"), planeDetected: planeDetected)
    }

    // MARK: - Pure helpers (unit tested)

    static func bodyPose(
        fromCameraTransform transform: simd_float4x4,
        previousForward: SIMD3<Float>
    ) -> BodyPose {
        let position = translation(of: transform)
        let forward = Geometry.horizontalForward(fromCameraTransform: transform) ?? previousForward
        return BodyPose(position: position, forward: forward)
    }

    static func summary(from state: ARCamera.TrackingState) -> TrackingSummary {
        switch state {
        case .normal:
            return .normal
        case .notAvailable:
            return .limited("Not available")
        case .limited(let reason):
            switch reason {
            case .initializing:
                return .initializing
            case .excessiveMotion:
                return .limited("Moving too fast")
            case .insufficientFeatures:
                return .limited("Not enough texture")
            case .relocalizing:
                return .limited("Relocalizing")
            @unknown default:
                return .limited("Limited")
            }
        }
    }

    static func translation(of transform: simd_float4x4) -> SIMD3<Float> {
        let column = transform.columns.3
        return SIMD3<Float>(column.x, column.y, column.z)
    }

    // MARK: - Private

    private func updatePlanes(addedOrUpdated: [ARAnchor], removed: [ARAnchor]) {
        for anchor in addedOrUpdated {
            guard let plane = anchor as? ARPlaneAnchor else {
                continue
            }
            if plane.alignment == .horizontal {
                horizontalPlaneHeights[plane.identifier] = plane.transform.columns.3.y
            }
        }
        for anchor in removed {
            horizontalPlaneHeights.removeValue(forKey: anchor.identifier)
        }

        let detected = !horizontalPlaneHeights.isEmpty
        if detected != planeDetected {
            logger.info("Horizontal plane detected: \(detected, privacy: .public)")
            setStatus(tracking: trackingSummary, planeDetected: detected)
        }
    }

    private func setStatus(tracking: TrackingSummary, planeDetected detected: Bool) {
        trackingSummary = tracking
        planeDetected = detected
        refreshDebugLabel()
        onStatusChange?(tracking, detected)
    }

    // MARK: - On-screen debug readout (device testing)

    private func installDebugLabel() {
        debugLabel.numberOfLines = 0
        debugLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        debugLabel.textColor = UIColor.white
        debugLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        debugLabel.isUserInteractionEnabled = false
        debugLabel.translatesAutoresizingMaskIntoConstraints = false
        arView.addSubview(debugLabel)

        let guide = arView.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            debugLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            debugLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            debugLabel.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -8)
        ])
        refreshDebugLabel()
    }

    private func refreshDebugLabel() {
        debugLabel.isHidden = !debugMarkers.isEnabled

        let planeText = planeDetected ? "yes" : "no"
        let lidarText = usesLiDAR ? "yes" : "no"
        let lines = [
            " tracking: \(Self.describe(trackingSummary)) ",
            " plane: \(planeText)   lidar: \(lidarText) ",
            " last tap: \(lastTapDescription) ",
            " detect test: \(lastDetectDescription) "
        ]
        debugLabel.text = lines.joined(separator: "\n")
    }

    private static func describe(_ summary: TrackingSummary) -> String {
        switch summary {
        case .notStarted:
            return "not started"
        case .initializing:
            return "initializing"
        case .normal:
            return "normal"
        case .limited(let reason):
            return "limited (\(reason))"
        }
    }

    // MARK: - Detection test (long-press, device only)

    private func installDetectionTestGesture() {
        let longPress = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleDetectionTestPress(_:))
        )
        longPress.minimumPressDuration = 0.5
        longPress.delegate = self
        arView.addGestureRecognizer(longPress)
    }

    /// Taps (tap-to-place) wait until a long-press has failed, so a long-press never also taps.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        let isMyLongPress = gestureRecognizer is UILongPressGestureRecognizer
        let otherIsTap = otherGestureRecognizer is UITapGestureRecognizer
        return isMyLongPress && otherIsTap
    }

    @objc private func handleDetectionTestPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else {
            return
        }
        let viewPoint = recognizer.location(in: arView)
        runDetectionTest(at: viewPoint)
    }

    /// Pretends Gemini found a tiny object at `viewPoint` and runs the full photo
    /// pipeline twice (with and without LiDAR), next to a direct screen raycast.
    private func runDetectionTest(at viewPoint: CGPoint) {
        let snapshot: Snapshot
        do {
            snapshot = try captureSnapshot()
        } catch {
            lastDetectDescription = "snapshot failed: \(error)"
            refreshDebugLabel()
            return
        }

        let uprightSize = CGSize(
            width: snapshot.sensorResolution.height,
            height: snapshot.sensorResolution.width
        )
        let upright = Self.uprightNormalized(
            fromViewPoint: viewPoint,
            viewSize: arView.bounds.size,
            uprightImageSize: uprightSize
        )
        let box = NormalizedRect(
            minX: upright.x - 0.005,
            minY: upright.y - 0.005,
            maxX: upright.x + 0.005,
            maxY: upright.y + 0.005
        )

        let directHits = arView.raycast(from: viewPoint, allowing: .estimatedPlane, alignment: .any)
        let direct = directHits.first.map { Self.translation(of: $0.worldTransform) }

        let withLiDAR = locate(box, in: snapshot)
        let noDepthSnapshot = Snapshot(
            id: snapshot.id,
            capturedAt: snapshot.capturedAt,
            uprightJPEG: snapshot.uprightJPEG,
            cameraTransform: snapshot.cameraTransform,
            intrinsics: snapshot.intrinsics,
            sensorResolution: snapshot.sensorResolution,
            uprightRotation: snapshot.uprightRotation,
            depth: nil
        )
        let withoutLiDAR = locate(box, in: noDepthSnapshot)

        debugMarkers.clear()
        if let direct {
            debugMarkers.show(at: direct, color: UIColor.red)
        }
        if withLiDAR.method == .lidarDepth {
            debugMarkers.show(at: withLiDAR.position, color: UIColor.blue)
        }
        debugMarkers.show(at: withoutLiDAR.position, color: UIColor.green)

        var parts: [String] = []
        let uprightText = String(format: "upright (%.2f, %.2f)", upright.x, upright.y)
        parts.append(uprightText)
        if withLiDAR.method == .lidarDepth {
            parts.append("lidar \(Self.offsetText(withLiDAR.position, from: direct))")
        } else {
            parts.append("lidar n/a")
        }
        parts.append("\(withoutLiDAR.method.rawValue) \(Self.offsetText(withoutLiDAR.position, from: direct))")
        lastDetectDescription = parts.joined(separator: ", ")

        logger.info("Detection test at \(String(describing: viewPoint), privacy: .public): \(self.lastDetectDescription, privacy: .public)")
        refreshDebugLabel()
    }

    private static func offsetText(_ position: SIMD3<Float>, from direct: SIMD3<Float>?) -> String {
        guard let direct else {
            return "(no red)"
        }
        let centimeters = simd_distance(position, direct) * 100
        return String(format: "%.1f cm", centimeters)
    }

    /// View point -> UPRIGHT normalized image point, assuming the preview shows the upright
    /// camera image aspect-FILLED (centered, cropped). Independent of ImageSpace on purpose,
    /// so the detection test really checks the upright -> sensor mapping.
    static func uprightNormalized(
        fromViewPoint point: CGPoint,
        viewSize: CGSize,
        uprightImageSize: CGSize
    ) -> NormalizedPoint {
        let scale = max(
            viewSize.width / uprightImageSize.width,
            viewSize.height / uprightImageSize.height
        )
        let displayedWidth = uprightImageSize.width * scale
        let displayedHeight = uprightImageSize.height * scale
        let cropX = (displayedWidth - viewSize.width) / 2
        let cropY = (displayedHeight - viewSize.height) / 2

        let x = (point.x + cropX) / displayedWidth
        let y = (point.y + cropY) / displayedHeight
        return NormalizedPoint(x: Double(x), y: Double(y))
    }

    private static func format(_ position: SIMD3<Float>) -> String {
        return String(format: "(%.2f, %.2f, %.2f)", position.x, position.y, position.z)
    }
}
