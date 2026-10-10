import Foundation
import UIKit
import os

@MainActor
final class EchoraCoordinator: ObservableObject {
    @Published private(set) var state: EchoraState = .setup
    @Published private(set) var status = SystemStatus()
    @Published private(set) var debug = DebugInfo()
    @Published var participantId: String = "P01"
    @Published var mode: RoundMode = .echora
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

    /// The phone's horizontal forward at the moment the AirPods reference was set
    /// (connect or calibrate). While head tracking is active, the listener faces this
    /// direction turned by the AirPods yaw, so the phone's live heading is ignored and
    /// turning the phone together with your head is not counted twice.
    /// nil = capture it from the next body pose.
    private var headingReference: SIMD3<Float>?
    private var lastAutoCalibrationAttempt = Date.distantPast

    /// Search trajectory of the current round (CONTRACT 3.6, v1.5). Uploaded on FOUND.
    private var roundSamples: [RoundSample] = []
    private var lastSampleTime = Date.distantPast
    private let sampleInterval: TimeInterval = 0.1
    private let maximumSamples = 3000   // 5 minutes at 10 Hz
    private let autoCalibrationRetryInterval: TimeInterval = 0.25

    /// True while push-to-talk is held during a round (.guiding / .narrating).
    /// The round keeps running; the release decides between "calibrate" and a new object.
    private var isListeningMidRound = false
    /// When the mid-round push-to-talk was pressed. A spoken "found" ends the round
    /// here, not when the transcript arrives (the user touched the object before pressing).
    private var midRoundPressTime: Date?

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
        return .echora
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
        let body = environment.perception.currentBodyPose()
        calibratePair(phoneForward: body?.forward)
    }

    /// Takes the AirPods reference and the phone heading at the SAME instant.
    /// If either is missing (no AirPods motion yet, no camera pose yet), the pair stays
    /// unset and handleBodyPose retries on a later frame.
    private func calibratePair(phoneForward: SIMD3<Float>?) {
        environment.headTracker.calibrate()
        status.headTracking = environment.headTracker.status

        let airPodsCalibrated = environment.headTracker.status == .calibrated
        guard airPodsCalibrated, let phoneForward else {
            headingReference = nil
            logger.info("Head calibration pending (AirPods calibrated: \(airPodsCalibrated, privacy: .public))")
            return
        }
        headingReference = phoneForward
        logger.info("Head calibrated, heading reference \(String(describing: phoneForward), privacy: .public)")
    }

    func beginVoiceRequest() {
        let midRound = isInRound
        guard canStartRequest || midRound else {
            logger.info("Ignoring voice press in state \(String(describing: self.state), privacy: .public)")
            return
        }
        guard !isListeningMidRound else {
            return
        }

        // Pressing means facing the phone: recalibrate now, before anything is said.
        calibrateHeadForRequest()

        do {
            try environment.voice.startListening()
            environment.audio.playEarcon(.listeningStart)
            if midRound {
                // Keep the round (and its timer and cue) running while the user speaks.
                isListeningMidRound = true
                midRoundPressTime = Date()
            } else {
                state = .listening
            }
        } catch {
            logger.error("startListening failed: \(error.localizedDescription, privacy: .public)")
            if midRound {
                return
            }
            handleError(.speechFailed(error.localizedDescription))
        }
    }

    func endVoiceRequest() {
        if isListeningMidRound {
            isListeningMidRound = false
            Task {
                let transcript = await environment.voice.stopListening()
                environment.audio.playEarcon(.listeningEnd)
                handleMidRoundTranscript(transcript)
            }
            return
        }

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
            if Self.isFoundCommand(trimmed) {
                // No round running: nothing to finish, and never send "found" to Gemini.
                logger.info("Voice command: found, but no round is running")
                state = readyOrSetup
                return
            }
            if Self.isCalibrateCommand(trimmed) {
                // Already calibrated on press. Confirm and stay ready.
                logger.info("Voice command: calibrate")
                environment.audio.playEarcon(.located)
                state = readyOrSetup
                return
            }
            state = .ready
            startRequest(utterance: trimmed)
        }
    }

    /// Release during a round. "calibrate" / "recenter" / silence: the press already
    /// recalibrated, so confirm and keep the same round and timer. Anything else is a
    /// new object: drop the current round (no result) and start a new request.
    private func handleMidRoundTranscript(_ transcript: String) {
        guard isInRound else {
            // Round ended (FOUND / Cancel) while the button was held.
            return
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let pressTime = midRoundPressTime ?? Date()
        midRoundPressTime = nil

        if Self.isFoundCommand(trimmed) {
            logger.info("Voice command: found")
            finishRound(endedAt: pressTime)
            return
        }
        if trimmed.isEmpty || Self.isCalibrateCommand(trimmed) {
            logger.info("Mid-round recalibration, round continues")
            environment.audio.playEarcon(.located)
            return
        }

        logger.info("Mid-round new request \"\(trimmed, privacy: .public)\", dropping current round")
        stopGuidance()
        startRequest(utterance: trimmed)
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
        calibrateHeadForRequest()
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
            // A tap that starts a round means you're holding or facing the phone, like a request.
            // (Taps during a round only move the target: no recalibration, so the sound doesn't jump.)
            calibrateHeadForRequest()
            environment.audio.playEarcon(.located)
            beginGuidance(for: target)
        case .listening, .locating:
            logger.info("Ignoring tap while a request is in flight")
        }
    }

    func markFound() {
        finishRound(endedAt: Date())
    }

    /// Ends the round with a successful result. Operator FOUND uses "now"; a spoken
    /// "found" uses the push-to-talk press time.
    private func finishRound(endedAt: Date) {
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

        stopMidRoundListening()

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

        let samples = roundSamples
        roundSamples = []
        Task {
            await environment.telemetry.report(result)
            if !samples.isEmpty {
                await environment.telemetry.reportSamples(samples)
            }
            status.pendingUploads = environment.telemetry.pendingCount
        }
    }

    /// 10 Hz while the round timer runs (spoken mode: after the first utterance starts).
    private func recordSampleIfDue(
        round: ActiveRound,
        listener: ListenerPose,
        head: HeadRotation,
        target: AnchoredTarget
    ) {
        guard let timerStart = roundTimerStartedAt else {
            return
        }
        guard roundSamples.count < maximumSamples else {
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastSampleTime) >= sampleInterval else {
            return
        }
        lastSampleTime = now

        let sample = Self.makeSample(
            roundId: round.id,
            mode: round.mode,
            secondsSinceStart: now.timeIntervalSince(timerStart),
            listener: listener,
            head: head,
            target: target.worldPosition
        )
        roundSamples.append(sample)
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
        stopMidRoundListening()
        stopGuidance()
        roundSamples = []   // cancelled rounds upload nothing
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
        if mode == .echora {
            mode = .spokenDirections
        } else {
            mode = .echora
        }
    }

    // MARK: - Request pipeline

    private var isInRound: Bool {
        switch state {
        case .guiding, .narrating:
            return true
        default:
            return false
        }
    }

    private func stopMidRoundListening() {
        guard isListeningMidRound else {
            return
        }
        isListeningMidRound = false
        midRoundPressTime = nil
        Task {
            _ = await environment.voice.stopListening()
        }
    }

    private var canStartRequest: Bool {
        switch state {
        case .ready, .found, .error:
            return true
        default:
            return false
        }
    }

    private var readyOrSetup: EchoraState {
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
        } catch let error as EchoraError {
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
        } catch let error as EchoraError {
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

        roundSamples = []
        lastSampleTime = Date.distantPast

        switch mode {
        case .echora:
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

    private func handleError(_ error: EchoraError) {
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
            self?.handleHeadTrackingStatus(headStatus)
        }
    }

    /// Blind users can't find a Calibrate button, so every request recalibrates.
    /// Asking means reaching for or holding the phone in front of you, so you're
    /// almost certainly facing it. Also cancels AirPods drift on every request.
    private func calibrateHeadForRequest() {
        guard Self.isHeadTrackingActive(status.headTracking) else {
            return
        }
        logger.info("Auto-calibrating head at request start")
        calibrateHead()
    }

    private func handleHeadTrackingStatus(_ headStatus: HeadTrackingStatus) {
        status.headTracking = headStatus

        // Only our own calibratePair produces a valid pair (status .calibrated).
        // .connected means the AirPods picked or reset their reference on their own
        // (first motion, reconnect), so the pair is stale: recalibrate on the next frame.
        // .disconnected / .unavailable: fall back to the phone's live heading.
        if headStatus != .calibrated {
            if headingReference != nil {
                logger.info("Head tracking \(String(describing: headStatus), privacy: .public), heading reference reset")
            }
            headingReference = nil
        }
    }

    private func handleBodyPose(_ body: BodyPose) {
        let headActive = Self.isHeadTrackingActive(status.headTracking)
        if headActive && headingReference == nil {
            let now = Date()
            if now.timeIntervalSince(lastAutoCalibrationAttempt) >= autoCalibrationRetryInterval {
                lastAutoCalibrationAttempt = now
                logger.info("Auto-calibrating head (startup or AirPods reconnect)")
                calibratePair(phoneForward: body.forward)
            }
        }

        let target: AnchoredTarget
        let round: ActiveRound
        let isGuiding: Bool
        switch state {
        case .guiding(let currentTarget, let currentRound):
            target = currentTarget
            round = currentRound
            isGuiding = true
        case .narrating(let currentTarget, let currentRound):
            target = currentTarget
            round = currentRound
            isGuiding = false
        default:
            return
        }

        let head = environment.headTracker.currentRotation()
        let listenerBody = Self.listenerBody(
            body: body,
            headingReference: headingReference,
            headTrackingActive: headActive
        )
        let listener = ListenerPoseMath.compose(body: listenerBody, head: head, rig: Config.rig)

        // Audio only in Echora mode. Spoken mode still needs the pose for sampling.
        var cue: CueParameters?
        if isGuiding {
            environment.audio.updateListener(listener)
            let parameters = CueModulator.parameters(listener: listener, target: target)
            environment.audio.updateCue(parameters)
            cue = parameters
        }

        recordSampleIfDue(round: round, listener: listener, head: head, target: target)

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

    /// "found", "found it", "got it", "i got it". Case and punctuation ignored.
    nonisolated static func isFoundCommand(_ transcript: String) -> Bool {
        let lowered = transcript.lowercased()
        let keywords = ["found", "got it"]
        for keyword in keywords {
            if lowered.contains(keyword) {
                return true
            }
        }
        return false
    }

    /// "calibrate", "recalibrate", "recenter", "re-center", "center". Case and punctuation ignored.
    nonisolated static func isCalibrateCommand(_ transcript: String) -> Bool {
        let lowered = transcript.lowercased()
        let keywords = ["calibrate", "recenter", "re-center", "re center", "center"]
        for keyword in keywords {
            if lowered.contains(keyword) {
                return true
            }
        }
        return false
    }

    nonisolated static func makeSample(
        roundId: UUID,
        mode: RoundMode,
        secondsSinceStart: Double,
        listener: ListenerPose,
        head: HeadRotation,
        target: SIMD3<Float>
    ) -> RoundSample {
        let angle = Geometry.signedHorizontalAngleDegrees(
            from: listener.position,
            forward: listener.forward,
            to: target
        )
        let distance = Geometry.horizontalDistance(listener.position, target)
        let yawDegrees = head.yawRadians * 180 / Float.pi

        return RoundSample(
            roundId: roundId,
            secondsSinceStart: secondsSinceStart,
            mode: mode,
            angleDegrees: angle,
            distanceMeters: distance,
            headYawDegrees: yawDegrees
        )
    }

    nonisolated static func isHeadTrackingActive(_ headStatus: HeadTrackingStatus) -> Bool {
        return headStatus == .connected || headStatus == .calibrated
    }

    /// Phone gives the position. Direction comes from the AirPods (via `head` in
    /// ListenerPoseMath) anchored to `headingReference`. Without head tracking,
    /// the phone's live heading is the only direction we have.
    nonisolated static func listenerBody(
        body: BodyPose,
        headingReference: SIMD3<Float>?,
        headTrackingActive: Bool
    ) -> BodyPose {
        guard headTrackingActive, let reference = headingReference else {
            return body
        }
        return BodyPose(position: body.position, forward: reference)
    }

    nonisolated static func participantNumber(from id: String) -> Int? {
        let digits = id.filter { $0.isNumber }
        return Int(digits)
    }

    /// Races `operation` against a timer. Throws EchoraError.locatorTimeout if the timer wins.
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
                throw EchoraError.locatorTimeout
            }
            guard let first = try await group.next() else {
                throw EchoraError.locatorTimeout
            }
            group.cancelAll()
            return first
        }
    }
}
