import SwiftUI

/// PLACEHOLDER from the contracts v1 scaffold so the app runs on mocks.
/// Qimin owns UI/ and replaces this with the Part 4.10 design.
struct OperatorView: View {
    @EnvironmentObject private var coordinator: EchoraCoordinator
    @State private var typedRequest = ""
    @State private var isHoldingToAsk = false
    @State private var isShowingUserMode = false

    var body: some View {
        ZStack(alignment: .bottom) {
            PreviewContainer(previewView: coordinator.previewView) { point in
                coordinator.placeTargetAtTap(point)
            }
            .ignoresSafeArea()

            VStack(spacing: 12) {
                statusStrip
                studyControls
                Text(stateDescription)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                timerText
                voiceStatusCard
                controlRow
            }
            .padding()
            .background(.regularMaterial)
        }
        .onAppear {
            coordinator.onAppear()
        }
        .onDisappear {
            if isHoldingToAsk {
                isHoldingToAsk = false
                coordinator.endVoiceRequest()
            }
            coordinator.onDisappear()
        }
        .fullScreenCover(isPresented: $isShowingUserMode) {
            UserModeView()
                .environmentObject(coordinator)
        }
    }

    private var statusStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: EchoraTheme.smallSpacing) {
                statusChip(
                    coordinator.participantId,
                    systemImage: "person.fill"
                )
                statusChip(
                    coordinator.mode == .echora ? "Echora" : "Spoken",
                    systemImage: coordinator.mode == .echora
                        ? "waveform" : "text.bubble.fill"
                )
                statusChip(
                    trackingStatus.title,
                    systemImage: trackingStatus.icon,
                    health: trackingStatus.health,
                    accessibilityLabel: trackingStatus.accessibilityLabel
                )
                statusChip(
                    coordinator.status.planeDetected ? "Plane Found" : "No Plane",
                    systemImage: coordinator.status.planeDetected
                        ? "square.3.layers.3d.top.filled" : "square.dashed",
                    health: coordinator.status.planeDetected
                )
                statusChip(
                    headTrackingStatus.title,
                    systemImage: headTrackingStatus.icon,
                    health: headTrackingStatus.health
                )
                statusChip(
                    coordinator.status.backendReachable ? "Backend Online" : "Backend Offline",
                    systemImage: coordinator.status.backendReachable
                        ? "network" : "network.slash",
                    health: coordinator.status.backendReachable
                )
                statusChip(
                    "Uploads \(coordinator.status.pendingUploads)",
                    systemImage: coordinator.status.pendingUploads == 0
                        ? "checkmark.icloud.fill" : "icloud.and.arrow.up.fill",
                    health: coordinator.status.pendingUploads == 0
                )
            }
            .padding(.horizontal, 1)
        }
        .accessibilityLabel("System status")
    }

    private func statusChip(
        _ title: String,
        systemImage: String,
        health: Bool? = nil,
        accessibilityLabel: String? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(statusIconColor(for: health))

            Text(title)
                .foregroundStyle(EchoraTheme.primaryText)
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 10)
        .frame(minHeight: EchoraTheme.minimumTouchSize)
        .background(EchoraTheme.surface.opacity(0.94))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel ?? title)
    }

    private func statusIconColor(for health: Bool?) -> Color {
        switch health {
        case .some(true):
            return .green
        case .some(false):
            return .orange
        case .none:
            return EchoraTheme.secondaryText
        }
    }

    private var studyControls: some View {
        VStack(spacing: EchoraTheme.smallSpacing) {
            HStack(spacing: EchoraTheme.smallSpacing) {
                Label(coordinator.participantId, systemImage: "person.fill")
                    .font(.headline.monospacedDigit())
                    .accessibilityLabel("Participant \(coordinator.participantId)")

                Spacer(minLength: EchoraTheme.smallSpacing)

                Toggle("Practice", isOn: $coordinator.isPractice)
                    .fixedSize()
                    .accessibilityLabel("Practice round")

                Button {
                    coordinator.nextParticipant()
                } label: {
                    Label("Next", systemImage: "person.badge.plus")
                        .frame(minHeight: EchoraTheme.minimumTouchSize)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Moves to the next participant and selects their suggested first mode")
            }

            HStack(spacing: EchoraTheme.smallSpacing) {
                modeButton(
                    .echora,
                    title: "Echora",
                    systemImage: "waveform"
                )
                modeButton(
                    .spokenDirections,
                    title: "Spoken",
                    systemImage: "text.bubble.fill"
                )
            }
        }
        .padding(EchoraTheme.smallSpacing)
        .background(EchoraTheme.surface.opacity(0.96))
        .clipShape(
            RoundedRectangle(
                cornerRadius: EchoraTheme.cornerRadius,
                style: .continuous
            )
        )
    }

    private func modeButton(
        _ mode: RoundMode,
        title: String,
        systemImage: String
    ) -> some View {
        let isSelected = coordinator.mode == mode
        let isSuggested = coordinator.suggestedFirstMode == mode

        return Button {
            coordinator.mode = mode
        } label: {
            VStack(spacing: 2) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))

                Text(isSuggested ? "Suggested first" : " ")
                    .font(.caption2)
                    .opacity(isSuggested ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: EchoraTheme.minimumTouchSize)
            .foregroundStyle(isSelected ? EchoraTheme.forest : EchoraTheme.primaryText)
            .background(isSelected ? EchoraTheme.lime : Color.clear)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: EchoraTheme.cornerRadius / 2,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .overlay {
            RoundedRectangle(
                cornerRadius: EchoraTheme.cornerRadius / 2,
                style: .continuous
            )
            .stroke(
                isSuggested ? EchoraTheme.lime : EchoraTheme.secondaryText.opacity(0.25),
                lineWidth: isSuggested ? 2 : 1
            )
        }
        .accessibilityLabel("\(title) mode")
        .accessibilityValue(
            [isSelected ? "Selected" : nil, isSuggested ? "Suggested first" : nil]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

    private var trackingStatus: (
        title: String,
        icon: String,
        health: Bool?,
        accessibilityLabel: String
    ) {
        switch coordinator.status.tracking {
        case .notStarted:
            return ("AR Off", "camera.fill", false, "AR tracking has not started")
        case .initializing:
            return ("AR Starting", "hourglass", nil, "AR tracking is starting")
        case .normal:
            return ("AR Ready", "viewfinder.circle.fill", true, "AR tracking is ready")
        case .limited(let reason):
            return (
                "AR Limited",
                "exclamationmark.triangle.fill",
                false,
                "AR tracking is limited: \(reason)"
            )
        }
    }

    private var headTrackingStatus: (
        title: String,
        icon: String,
        health: Bool?
    ) {
        switch coordinator.status.headTracking {
        case .unavailable:
            return ("AirPods N/A", "airpods", false)
        case .disconnected:
            return ("AirPods Off", "airpods", false)
        case .connected:
            return ("AirPods Connected", "airpods", true)
        case .calibrated:
            return ("AirPods Ready", "airpods", true)
        }
    }

    private var timerText: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            if let elapsed = coordinator.elapsedSeconds {
                Text(String(format: "%.1f s", elapsed))
                    .font(.largeTitle.monospacedDigit())
            }
        }
    }

    private var voiceStatusCard: some View {
        HStack(spacing: EchoraTheme.regularSpacing) {
            Image(systemName: voiceStatusIcon)
                .font(.title2)
                .foregroundStyle(EchoraTheme.forest)
                .frame(
                    width: EchoraTheme.minimumTouchSize,
                    height: EchoraTheme.minimumTouchSize
                )
                .background(EchoraTheme.mint)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: EchoraTheme.smallSpacing) {
                Text(voiceStatusTitle)
                    .font(.headline)
                    .foregroundStyle(EchoraTheme.primaryText)

                Text(voiceStatusDetail)
                    .font(.subheadline)
                    .foregroundStyle(EchoraTheme.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EchoraTheme.regularSpacing)
        .background(EchoraTheme.surface)
        .clipShape(
            RoundedRectangle(
                cornerRadius: EchoraTheme.cornerRadius,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
    }

    private var controlRow: some View {
        VStack(spacing: EchoraTheme.regularSpacing) {
            holdToAskButton
            typedRequestRow
            quickPickRow

            Button {
                isShowingUserMode = true
            } label: {
                Label("Open full-screen user mode", systemImage: "hand.tap.fill")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: EchoraTheme.minimumTouchSize)
            }
            .buttonStyle(.borderedProminent)
            .tint(EchoraTheme.forest)
            .accessibilityHint("Opens a screen where you can hold anywhere to ask")

            if isGuidanceActive {
                Button {
                    coordinator.markFound()
                } label: {
                    Label("FOUND", systemImage: "checkmark.circle.fill")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: EchoraTheme.foundButtonHeight)
                }
                .buttonStyle(.borderedProminent)
                .tint(EchoraTheme.lime)
                .foregroundStyle(EchoraTheme.forest)
                .accessibilityLabel("Object found")
                .accessibilityHint("Ends the current round and records the completion time")
            }

            HStack(spacing: EchoraTheme.regularSpacing) {
                Button("Cancel") {
                    coordinator.cancel()
                }
                .frame(minHeight: EchoraTheme.minimumTouchSize)

                if isSpokenGuidanceActive {
                    Button {
                        coordinator.repeatDirections()
                    } label: {
                        Label("Repeat", systemImage: "repeat")
                    }
                    .frame(minHeight: EchoraTheme.minimumTouchSize)
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var holdToAskButton: some View {
        Label(
            isHoldingToAsk ? "Listening…" : "Hold to ask",
            systemImage: isHoldingToAsk ? "waveform" : "mic.fill"
        )
        .font(.title2.bold())
        .foregroundStyle(EchoraTheme.forest)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 64)
        .background(isHoldingToAsk ? EchoraTheme.lime : EchoraTheme.mint)
        .clipShape(
            RoundedRectangle(
                cornerRadius: EchoraTheme.cornerRadius,
                style: .continuous
            )
        )
        .contentShape(Rectangle())
        .opacity(canHoldToAsk ? 1 : 0.5)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    beginHoldingToAsk()
                }
                .onEnded { _ in
                    endHoldingToAsk()
                }
        )
        .allowsHitTesting(canHoldToAsk)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isHoldingToAsk ? "Listening" : "Hold to ask")
        .accessibilityHint("Hold while speaking, then release to submit your request")
        .accessibilityAddTraits(.isButton)
    }

    private var typedRequestRow: some View {
        HStack(spacing: EchoraTheme.smallSpacing) {
            TextField("Type an object, e.g. mug", text: $typedRequest)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit {
                    submitTypedRequest()
                }
                .accessibilityLabel("Object to find")

            Button("Ask") {
                submitTypedRequest()
            }
            .buttonStyle(.borderedProminent)
            .tint(EchoraTheme.forest)
            .frame(minHeight: EchoraTheme.minimumTouchSize)
            .disabled(!canSubmitTypedRequest || trimmedTypedRequest.isEmpty)
        }
    }

    private var quickPickRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: EchoraTheme.smallSpacing) {
                ForEach(Config.knownObjects, id: \.self) { object in
                    Button(object.capitalized) {
                        submitQuickPick(object)
                    }
                    .buttonStyle(.bordered)
                    .tint(EchoraTheme.forest)
                    .frame(minHeight: EchoraTheme.minimumTouchSize)
                    .disabled(!canSubmitTypedRequest)
                    .accessibilityLabel("Find \(object)")
                }
            }
            .padding(.horizontal, 1)
        }
        .accessibilityLabel("Quick object choices")
    }

    private var stateDescription: String {
        switch coordinator.state {
        case .setup:
            return "Setting up AR…"
        case .ready:
            return "Hold the microphone and ask for an object."
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

    private var isGuidanceActive: Bool {
        switch coordinator.state {
        case .guiding, .narrating:
            return true
        default:
            return false
        }
    }

    private var isSpokenGuidanceActive: Bool {
        if case .narrating = coordinator.state {
            return true
        }
        return false
    }

    private var voiceStatusIcon: String {
        switch coordinator.state {
        case .listening:
            return "waveform"
        case .locating:
            return "sparkles"
        case .guiding, .narrating:
            return "speaker.wave.2.fill"
        case .found:
            return "checkmark"
        case .error:
            return "exclamationmark"
        case .setup, .ready:
            return "mic.fill"
        }
    }

    private var voiceStatusTitle: String {
        switch coordinator.state {
        case .setup:
            return "Getting ready"
        case .ready:
            return "Ready to listen"
        case .listening:
            return "Listening"
        case .locating:
            return "Finding your object"
        case .guiding:
            return "Follow the sound"
        case .narrating:
            return "Listen for directions"
        case .found:
            return "Object found"
        case .error:
            return "We could not complete that request"
        }
    }

    private var voiceStatusDetail: String {
        switch coordinator.state {
        case .setup:
            return "Wait for camera tracking, then hold the microphone to ask."
        case .ready:
            return "Hold to ask, say something like “Look for my keys,” then release."
        case .listening:
            return "Say the name of the object you want to find."
        case .locating(let utterance):
            return "Heard: “\(utterance)”"
        case .guiding(let target, _):
            return "Echora is guiding you to \(target.label)."
        case .narrating(let target, _):
            return "Echora is describing the direction to \(target.label)."
        case .found(let result):
            return String(format: "Completed in %.1f seconds.", result.durationSeconds)
        case .error:
            return "Hold to ask and try again."
        }
    }

    private var canHoldToAsk: Bool {
        switch coordinator.state {
        case .ready, .listening, .guiding, .narrating, .found, .error:
            return true
        case .setup, .locating:
            return false
        }
    }

    private var canSubmitTypedRequest: Bool {
        switch coordinator.state {
        case .ready, .found, .error:
            return true
        default:
            return false
        }
    }

    private var trimmedTypedRequest: String {
        typedRequest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginHoldingToAsk() {
        guard canHoldToAsk, !isHoldingToAsk else {
            return
        }
        isHoldingToAsk = true
        coordinator.beginVoiceRequest()
    }

    private func endHoldingToAsk() {
        guard isHoldingToAsk else {
            return
        }
        isHoldingToAsk = false
        coordinator.endVoiceRequest()
    }

    private func submitTypedRequest() {
        guard canSubmitTypedRequest, !trimmedTypedRequest.isEmpty else {
            return
        }
        coordinator.submitTypedRequest(trimmedTypedRequest)
        typedRequest = ""
    }

    private func submitQuickPick(_ object: String) {
        guard canSubmitTypedRequest else {
            return
        }
        coordinator.submitTypedRequest(object)
        typedRequest = ""
    }
}
