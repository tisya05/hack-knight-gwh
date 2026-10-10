import SwiftUI

/// PLACEHOLDER from the contracts v1 scaffold so the app runs on mocks.
/// Qimin owns UI/ and replaces this with the Part 4.10 design.
struct OperatorView: View {
    @EnvironmentObject private var coordinator: EchoraCoordinator
    @State private var typedRequest = ""
    @State private var isHoldingToTalk = false

    var body: some View {
        ZStack(alignment: .bottom) {
            PreviewContainer(previewView: coordinator.previewView) { point in
                coordinator.placeTargetAtTap(point)
            }
            .ignoresSafeArea()

            VStack(spacing: 12) {
                statusStrip
                Text(stateDescription)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                timerText
                requestRow
                holdToTalkButton
                controlRow
            }
            .padding()
            .background(.regularMaterial)
        }
        .onAppear {
            coordinator.onAppear()
        }
        .onDisappear {
            coordinator.onDisappear()
        }
    }

    private var statusStrip: some View {
        HStack {
            Text(coordinator.participantId)
            Text(coordinator.status.planeDetected ? "plane ✓" : "no plane")
            Text(coordinator.status.backendReachable ? "backend ✓" : "backend ✗")
        }
        .font(.caption)
    }

    private var timerText: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            if let elapsed = coordinator.elapsedSeconds {
                Text(String(format: "%.1f s", elapsed))
                    .font(.largeTitle.monospacedDigit())
            }
        }
    }

    private var requestRow: some View {
        HStack {
            TextField("Type an object, e.g. mug", text: $typedRequest)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    coordinator.submitTypedRequest(typedRequest)
                }
            Button("Ask") {
                coordinator.submitTypedRequest(typedRequest)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// Temporary push-to-talk for testing the voice agent until the real OperatorView lands.
    private var holdToTalkButton: some View {
        Text(isHoldingToTalk ? "Listening… release when done" : "Hold to talk")
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(isHoldingToTalk ? Color.red : Color.blue)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .gesture(holdGesture)
    }

    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if isHoldingToTalk {
                    return
                }
                isHoldingToTalk = true
                coordinator.beginVoiceRequest()
            }
            .onEnded { _ in
                isHoldingToTalk = false
                coordinator.endVoiceRequest()
            }
    }

    private var controlRow: some View {
        HStack {
            Button("FOUND") {
                coordinator.markFound()
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            Button("Cancel") {
                coordinator.cancel()
            }
            Button("Next") {
                coordinator.nextParticipant()
            }
        }
    }

    private var stateDescription: String {
        switch coordinator.state {
        case .setup:
            return "Setting up AR…"
        case .ready:
            return "Ready. Tap the table or ask for an object."
        case .listening:
            return "Listening…"
        case .locating(let utterance):
            return "Locating \"\(utterance)\"…"
        case .guiding(let target, _):
            return "Echora guiding to \(target.label)"
        case .found(let result):
            return String(format: "Found in %.1f s", result.durationSeconds)
        case .error(let error):
            return "Error: \(String(describing: error))"
        }
    }
}
