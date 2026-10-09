import Foundation
import ARKit
import RealityKit
import UIKit
import os

/// Real `PerceptionService`: RealityKit ARView + ARKit world tracking.
/// Device only. AppEnvironment falls back to the mock when ARKit is unsupported (simulator).
///
/// This PR covers Layer 1 (session, body pose, tap-to-place, debug markers).
/// `captureSnapshot` and `place` land in tisya/snapshot-capture and the detection-placement PR.
final class ARSessionController: NSObject, PerceptionService, ARSessionDelegate {
    let previewView: UIView
    private(set) var trackingSummary: TrackingSummary = .notStarted
    private(set) var planeDetected = false

    var onBodyPoseUpdate: ((BodyPose) -> Void)?
    var onStatusChange: ((TrackingSummary, Bool) -> Void)?

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    private let arView: ARView
    private let debugMarkers: DebugMarkers
    private let debugLabel = UILabel()
    private let logger = Logger(subsystem: "com.gwh.echora", category: "Perception")

    private var latestBodyPose: BodyPose?
    private var lastForward = SIMD3<Float>(0, 0, -1)
    private var horizontalPlaneIDs = Set<UUID>()
    private var hasStartedOnce = false
    private var usesLiDAR = false

    /// Targets whose tap raycast missed and fell back to fixed depth. Drawn yellow instead of red.
    private var fallbackTargetIDs = Set<UUID>()
    private var lastTapDescription = "none"

    override init() {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        arView = view
        previewView = view
        debugMarkers = DebugMarkers(arView: view)
        super.init()

        view.session.delegate = self
        installDebugLabel()
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

    // MARK: - Snapshot and detection placement (later PRs)

    func captureSnapshot() throws -> Snapshot {
        logger.error("captureSnapshot not implemented yet (tisya/snapshot-capture)")
        throw EchoraError.cameraNotReady
    }

    func place(_ detection: Detection, from snapshot: Snapshot) async throws -> AnchoredTarget {
        logger.error("place(_:from:) not implemented yet (detection placement PR)")
        throw EchoraError.placementFailed
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
        updatePlanes(added: anchors, removed: [])
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        updatePlanes(added: [], removed: anchors)
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

    private func updatePlanes(added: [ARAnchor], removed: [ARAnchor]) {
        for anchor in added {
            guard let plane = anchor as? ARPlaneAnchor else {
                continue
            }
            if plane.alignment == .horizontal {
                horizontalPlaneIDs.insert(plane.identifier)
            }
        }
        for anchor in removed {
            horizontalPlaneIDs.remove(anchor.identifier)
        }

        let detected = !horizontalPlaneIDs.isEmpty
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
            " last tap: \(lastTapDescription) "
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

    private static func format(_ position: SIMD3<Float>) -> String {
        return String(format: "(%.2f, %.2f, %.2f)", position.x, position.y, position.z)
    }
}
