import Foundation
import os

final class MockDirectionsNarrator: DirectionsNarrating {
    var onFirstUtteranceStarted: (() -> Void)?

    private let logger = Logger(subsystem: "com.gwh.echora", category: "MockNarrator")
    private var target: AnchoredTarget?
    private var poseProvider: (() -> BodyPose?)?
    private var repeatTimer: Timer?
    private var firstUtteranceWorkItem: DispatchWorkItem?

    func start(
        target: AnchoredTarget,
        repeatIntervalSeconds: Double,
        poseProvider: @escaping () -> BodyPose?
    ) {
        stop()
        self.target = target
        self.poseProvider = poseProvider

        speak()

        let workItem = DispatchWorkItem { [weak self] in
            self?.onFirstUtteranceStarted?()
        }
        firstUtteranceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)

        repeatTimer = Timer.scheduledTimer(withTimeInterval: repeatIntervalSeconds, repeats: true) { [weak self] _ in
            self?.speak()
        }
    }

    func repeatNow() {
        speak()
    }

    func stop() {
        firstUtteranceWorkItem?.cancel()
        firstUtteranceWorkItem = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
        target = nil
        poseProvider = nil
    }

    private func speak() {
        guard let target else {
            return
        }
        // Fixed phrase until Moon lands DirectionsPhraser.
        let phrase = "\(target.label). 12 o'clock, about 40 centimeters."
        logger.info("speak: \(phrase, privacy: .public)")
    }
}
