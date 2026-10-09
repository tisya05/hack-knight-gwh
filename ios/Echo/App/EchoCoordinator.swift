import Foundation
import UIKit
import os

@MainActor
final class EchoCoordinator: ObservableObject {
    @Published private(set) var state: EchoState = .setup
    @Published private(set) var status = SystemStatus()
    @Published private(set) var debug = DebugInfo()
    @Published var participantId: String = "P01"
    @Published var mode: RoundMode = .echo
    @Published var isPractice: Bool = false
    @Published var cueSound: CueSoundID = .primary {
        didSet {
            environment.audio.setCueSound(cueSound)
        }
    }

    private let environment: AppEnvironment
    private let logger = Logger(subsystem: "com.gwh.echora", category: "Coordinator")

    /// When the round timer actually started (guidance output began). nil = not running.
    private var roundTimerStartedAt: Date?
    private var requestTask: Task<Void, Never>?
    private var errorResetTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var lastDebugPublish = Date.distantPast
    private let debugPublishInterval: TimeInterval = 0.1
    private var hasAppeared = false

    init(environment: AppEnvironment) {
        self.environment = environment
        self.mode = suggestedFirstMode
    }

    // MARK: - Read-only helpers for UI

    /// The camera preview to embed. UI wraps this in a UIViewRepresentable.
    var previewView: UIView {
        environment.perception.previewView
    }

    var elapsedSeconds: Double? {
        guard let startedAt = roundTimerStartedAt else {
            return nil
        }
        return Date().timeIntervalSince(startedAt)
    }

    var suggestedFirstMode: RoundMode {
        let number = Self.participantNumber(from: participantId) ?? 1
        if number % 2 == 1 {
            return .spokenDirections
        }
        return .echo
    }

    // MARK: - Lifecycle

    func onAppear() {
        guard !hasAppeared else {
            return
        }
        hasAppeared = true
        logger.info("onAppear")

        wireCallbacks()

        do {
            try environment.audio.start()
            environment.audio.setCueSound(cueSound)
        } catch {
            logger.error("Audio failed to start: \(error.localizedDescription, privacy: .public)")
            handleError(.audioEngineFailed(error.localizedDescription))
        }

        environment.perception.start()
        environment.headTracker.start()
        status.headTracking = environment.headTracker.status

        Task {
            let authorized = await environment.voice.requestAuthorization()
            if !authorized {
                logger.warning("Speech not authorized. Typed requests still work.")
            }
        }

        startHealthPolling()
    }

    func onDisappear() {
        logger.info("onDisappear")
        hasAppeared = false
        healthTask?.cancel()
        healthTask = nil
        stopGuidance()
        environment.perception.pause()
        environment.headTracker.stop()
        environment.audio.stop()
    }

    // MARK: - Operator intents

    func calibrateHead() {
        environment.headTracker.calibrate()
        status.headTracking = environment.headTracker.status
    }

    func beginVoiceRequest() {
        guard canStartRequest else {
            logger.info("Ignoring voice press in state \(String(describing: self.state), privacy: .public)")
            return
        }
        do {
            try environment.voice.startListening()
            environment.audio.playEarcon(.listeningStart)
            state = .listening
        } catch {
            logger.error("startListening failed: \(error.localizedDescription, privacy: .public)")
            handleError(.speechFailed(error.localizedDescription))
        }
    }

    func endVoiceRequest() {
        guard state == .listening else {
            return
        }
        Task {
            let transcript = await environment.voice.stopListening()
            environment.audio.playEarcon(.listeningEnd)
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                handleError(.speechFailed("Nothing heard"))
                return
            }
            state = .ready
            startRequest(utterance: trimmed)
        }
    }

    func submitTypedRequest(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard canStartRequest else {
            logger.info("Ignoring typed request in state \(String(describing: self.state), privacy: .public)")
            return
        }
        startRequest(utterance: trimmed)
    }

    func placeTargetAtTap(_ point: CGPoint) {
        let target: AnchoredTarget
        do {
            target = try environment.perception.placeAtViewPoint(point, label: "tap")
        } catch {
            logger.error("Tap placement failed: \(error.localizedDescription, privacy: .public)")
            handleError(.placementFailed)
            return
        }
        logger.info("Tap placed target at \(String(describing: target.worldPosition), privacy: .public)")

        environment.perception.clearDebugMarkers()
        environment.perception.showDebugMarker(for: target)
        debug.placement = target.placement
        debug.targetPosition = target.worldPosition

        // Manual override during a round: move the target, keep the round and its timer.
        switch state {
        case .guiding(_, let round):
            environment.audio.setTarget(target)
            state = .guiding(target: target, round: round)
        case .narrating(_, let round):
            environment.narrator.stop()
            startNarrator(for: target)
            state = .narrating(target: target, round: round)
        case .ready, .found, .error, .setup:
            environment.audio.playEarcon(.located)
            beginGuidance(for: target)
        case .listening, .locating:
            logger.info("Ignoring tap while a request is in flight")
        }
    }

    func markFound() {
        let target: AnchoredTarget
        let round: ActiveRound
        switch state {
        case .guiding(let currentTarget, let currentRound):
            target = currentTarget
            round = currentRound
        case .narrating(let currentTarget, let currentRound):
            target = currentTarget
            round = currentRound
        default:
            return
        }

        let endedAt = Date()
        let startedAt = roundTimerStartedAt ?? round.startedAt
        let duration = max(0, endedAt.timeIntervalSince(startedAt))

        stopGuidance()
        environment.audio.playEarcon(.found)

        let headStatus = status.headTracking
        let headTrackingUsed = headStatus == .connected || headStatus == .calibrated

        let result = RoundResult(
            id: round.id,
            participantId: participantId,
            mode: round.mode,
            objectLabel: round.objectLabel,
            durationSeconds: duration,
            success: true,
            isPractice: isPractice,
            headTrackingUsed: headTrackingUsed,
            placement: target.placement,
            startedAt: startedAt,
            appVersion: Config.appVersion
        )
        logger.info("Round found in \(duration, privacy: .public) s, mode \(round.mode.rawValue, privacy: .public)")
        state = .found(result: result)

        Task {
            await environment.telemetry.report(result)
            status.pendingUploads = environment.telemetry.pendingCount
        }
    }

    func cancel() {
        logger.info("cancel in state \(String(describing: self.state), privacy: .public)")
        requestTask?.cancel()
        requestTask = nil
        if state == .listening {
            Task {
                _ = await environment.voice.stopListening()
            }
        }
        stopGuidance()
        errorResetTask?.cancel()
        state = readyOrSetup
    }

    func repeatDirections() {
        guard case .narrating = state else {
            return
        }
        environment.narrator.repeatNow()
    }

    func nextParticipant() {
        let current = Self.participantNumber(from: participantId) ?? 0
        participantId = String(format: "P%02d", current + 1)
        mode = suggestedFirstMode
        cancel()
        logger.info("Next participant \(self.participantId, privacy: .public), first mode \(self.mode.rawValue, privacy: .public)")
    }

    func toggleMode() {
        if mode == .echo {
            mode = .spokenDirections
        } else {
            mode = .echo
        }
    }

    // MARK: - Request pipeline

    private var canStartRequest: Bool {
        switch state {
        case .ready, .found, .error:
            return true
        default:
            return false
        }
    }

    private var readyOrSetup: EchoState {
        if status.tracking == .normal {
            return .ready
        }
        return .setup
    }

    private func startRequest(utterance: String) {
        errorResetTask?.cancel()

        let snapshot: Snapshot
        do {
            snapshot = try environment.perception.captureSnapshot()
        } catch let error as EchoError {
            handleError(error)
            return
        } catch {
            handleError(.cameraNotReady)
            return
        }

        debug.lastUtterance = utterance
        debug.lastSnapshotJPEG = snapshot.uprightJPEG
        debug.lastDetection = nil
        state = .locating(utterance: utterance)
        logger.info("Locating \"\(utterance, privacy: .public)\"")

        requestTask = Task {
            await runLocateAndPlace(utterance: utterance, snapshot: snapshot)
        }
    }

    private func runLocateAndPlace(utterance: String, snapshot: Snapshot) async {
        let locator = environment.locator
        let perception = environment.perception
        let started = Date()

        do {
            let detection = try await Self.withTimeout(seconds: Config.geminiTimeoutSeconds + 1) {
                try await locator.locate(utterance: utterance, in: snapshot)
            }
            try Task.checkCancellation()

            let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            debug.locatorLatencyMs = latencyMs
            debug.lastDetection = detection
            logger.info("Located \(detection.label, privacy: .public) in \(latencyMs, privacy: .public) ms")

            let target = try await perception.place(detection, from: snapshot)
            try Task.checkCancellation()

            debug.placement = target.placement
            debug.targetPosition = target.worldPosition
            perception.clearDebugMarkers()
            perception.showDebugMarker(for: target)
            environment.audio.playEarcon(.located)
            beginGuidance(for: target)
        } catch is CancellationError {
            logger.info("Request cancelled")
        } catch let error as EchoError {
            handleError(error)
        } catch {
            handleError(.locatorFailed(error.localizedDescription))
        }
    }

    private func beginGuidance(for target: AnchoredTarget) {
        let round = ActiveRound(
            id: UUID(),
            mode: mode,
            objectLabel: target.label,
            startedAt: Date()
        )

        switch mode {
        case .echo:
            environment.audio.setTarget(target)
            roundTimerStartedAt = Date()
            state = .guiding(target: target, round: round)
        case .spokenDirections:
            roundTimerStartedAt = nil
            state = .narrating(target: target, round: round)
            startNarrator(for: target)
        }
    }

    private func startNarrator(for target: AnchoredTarget) {
        let perception = environment.perception
        environment.narrator.onFirstUtteranceStarted = { [weak self] in
            guard let self else {
                return
            }
            if self.roundTimerStartedAt == nil {
                self.roundTimerStartedAt = Date()
                self.logger.info("Spoken round timer started")
            }
        }
        environment.narrator.start(
            target: target,
            repeatIntervalSeconds: Config.spokenRepeatIntervalSeconds,
            poseProvider: {
                perception.currentBodyPose()
            }
        )
    }

    private func stopGuidance() {
        switch state {
        case .guiding:
            environment.audio.clearTarget()
        case .narrating:
            environment.narrator.stop()
        default:
            break
        }
        roundTimerStartedAt = nil
        debug.cue = nil
    }

    private func handleError(_ error: EchoError) {
        logger.error("Error: \(String(describing: error), privacy: .public)")
        stopGuidance()
        environment.audio.playEarcon(.notFound)
        state = .error(error)

        errorResetTask?.cancel()
        errorResetTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled {
                return
            }
            if case .error = state {
                state = readyOrSetup
            }
        }
    }

    // MARK: - Real-time loop (Part 2.2)

    private func wireCallbacks() {
        environment.perception.onBodyPoseUpdate = { [weak self] body in
            self?.handleBodyPose(body)
        }
        environment.perception.onStatusChange = { [weak self] tracking, planeDetected in
            self?.handlePerceptionStatus(tracking: tracking, planeDetected: planeDetected)
        }
        environment.headTracker.onStatusChange = { [weak self] headStatus in
            self?.status.headTracking = headStatus
        }
    }

    private func handleBodyPose(_ body: BodyPose) {
        guard case .guiding(let target, _) = state else {
            return
        }

        let head = environment.headTracker.currentRotation()
        let listener = ListenerPoseMath.compose(body: body, head: head, rig: Config.rig)
        environment.audio.updateListener(listener)

        let cue = CueModulator.parameters(listener: listener, target: target)
        environment.audio.updateCue(cue)

        let now = Date()
        guard now.timeIntervalSince(lastDebugPublish) >= debugPublishInterval else {
            return
        }
        lastDebugPublish = now

        var updated = debug
        updated.cue = cue
        updated.headRotation = head
        updated.targetPosition = target.worldPosition
        updated.targetDistanceMeters = Geometry.horizontalDistance(listener.position, target.worldPosition)
        updated.targetAngleDegrees = Geometry.signedHorizontalAngleDegrees(
            from: listener.position,
            forward: listener.forward,
            to: target.worldPosition
        )
        debug = updated
    }

    private func handlePerceptionStatus(tracking: TrackingSummary, planeDetected: Bool) {
        status.tracking = tracking
        status.planeDetected = planeDetected
        if tracking == .normal && state == .setup {
            state = .ready
        }
    }

    // MARK: - Backend health

    private func startHealthPolling() {
        healthTask?.cancel()
        healthTask = Task {
            while !Task.isCancelled {
                let reachable = await environment.telemetry.ping()
                status.backendReachable = reachable
                status.pendingUploads = environment.telemetry.pendingCount
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    // MARK: - Helpers

    nonisolated static func participantNumber(from id: String) -> Int? {
        let digits = id.filter { $0.isNumber }
        return Int(digits)
    }

    /// Races `operation` against a timer. Throws EchoError.locatorTimeout if the timer wins.
    private static func withTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw EchoError.locatorTimeout
            }
            guard let first = try await group.next() else {
                throw EchoError.locatorTimeout
            }
            group.cancelAll()
            return first
        }
    }
}
