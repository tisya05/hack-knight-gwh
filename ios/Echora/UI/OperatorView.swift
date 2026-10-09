import SwiftUI

/// PLACEHOLDER from the contracts v1 scaffold so the app runs on mocks.
/// Qimin owns UI/ and replaces this with the Part 4.10 design.
struct OperatorView: View {
    @EnvironmentObject private var coordinator: EchoraCoordinator
    @State private var typedRequest = ""

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
            Text(coordinator.mode == .echora ? "Echora" : "Spoken")
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
            Button("Mode") {
                coordinator.toggleMode()
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
        case .narrating(let target, _):
            return "Speaking directions to \(target.label)"
        case .found(let result):
            return String(format: "Found in %.1f s", result.durationSeconds)
        case .error(let error):
            return "Error: \(String(describing: error))"
        }
    }
}
