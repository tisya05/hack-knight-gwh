import SwiftUI
import UIKit

/// A simple, accessible screen for a blind or visually impaired participant.
/// Holding anywhere starts listening; releasing submits the spoken request.
struct UserModeView: View {
    @EnvironmentObject private var coordinator: EchoraCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var isHoldingToAsk = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            holdAnywhereSurface

#if DEBUG
            developerExitButton
#endif
        }
        .onChange(of: coordinator.state) { _, newState in
            playStateHaptic(for: newState)
        }
        .onDisappear {
            if isHoldingToAsk {
                endHoldingToAsk()
            }
        }
    }

#if DEBUG
    private var developerExitButton: some View {
        Button {
            dismiss()
        } label: {
            Label("Dev Mode", systemImage: "xmark")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(minHeight: EchoraTheme.minimumTouchSize)
                .foregroundStyle(.white)
                .background(.black.opacity(0.45))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, EchoraTheme.smallSpacing)
        .padding(.trailing, EchoraTheme.regularSpacing)
        .accessibilityLabel("Exit user mode")
        .accessibilityHint("Returns to the operator controls")
    }
#endif

    private var holdAnywhereSurface: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea()

            Circle()
                .fill(EchoraTheme.lime.opacity(isHoldingToAsk ? 0.85 : 0.12))
                .frame(width: isHoldingToAsk ? 460 : 220)
                .blur(radius: isHoldingToAsk ? 22 : 8)
                .shadow(
                    color: EchoraTheme.lime.opacity(isHoldingToAsk ? 0.9 : 0),
                    radius: 50
                )

            VStack(spacing: EchoraTheme.largeSpacing) {
                Spacer()

                Image(systemName: isHoldingToAsk ? "waveform.circle.fill" : "hand.tap.fill")
                    .font(.system(size: 92, weight: .bold))
                    .foregroundStyle(isHoldingToAsk ? EchoraTheme.forest : EchoraTheme.lime)
                    .symbolEffect(.pulse, isActive: isHoldingToAsk)

                Text(isHoldingToAsk ? "Listening…" : "Hold anywhere to ask")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(foregroundColor)

                Text(statusMessage)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(foregroundColor.opacity(0.85))
                    .padding(.horizontal, EchoraTheme.largeSpacing)

                Spacer()

                Text(isHoldingToAsk ? "Release when you finish speaking" : "Press, speak, then release")
                    .font(.headline)
                    .foregroundStyle(foregroundColor)
                    .padding(.bottom, 48)
            }
        }
        .contentShape(Rectangle())
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
        .opacity(canHoldToAsk ? 1 : 0.72)
        .animation(.easeOut(duration: 0.16), value: isHoldingToAsk)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold anywhere to ask for an object")
        .accessibilityValue(accessibilityStatus)
        .accessibilityHint(
            "Say an object, or say calibrate to recenter. During guidance, use Magic Tap to mark the object found."
        )
        .accessibilityAction(.magicTap) {
            markFoundWithMagicTap()
        }
        .accessibilityAction(.escape) {
            dismiss()
        }
    }

    private var backgroundColor: Color {
        isHoldingToAsk ? EchoraTheme.mint : EchoraTheme.forest
    }

    private var foregroundColor: Color {
        isHoldingToAsk ? EchoraTheme.forest : .white
    }

    private var statusMessage: String {
        if isHoldingToAsk {
            return "Say the name of the object you want to find."
        }

        switch coordinator.state {
        case .setup:
            return "Getting the camera ready."
        case .ready:
            return "Ready."
        case .listening:
            return "Listening."
        case .locating(let utterance):
            return "Finding \(utterance)."
        case .guiding(let target, _):
            return "Follow the sound to \(target.label). Magic Tap when you find it."
        case .narrating(let target, _):
            return "Listen for directions to \(target.label). Magic Tap when you find it."
        case .found(let result):
            return String(format: "Found in %.1f seconds.", result.durationSeconds)
        case .error:
            return "Something went wrong. Hold anywhere to try again."
        }
    }

    private var accessibilityStatus: String {
        isHoldingToAsk ? "Listening" : statusMessage
    }

    private var canHoldToAsk: Bool {
        switch coordinator.state {
        case .ready, .listening, .guiding, .narrating, .found, .error:
            return true
        case .setup, .locating:
            return false
        }
    }

    private func beginHoldingToAsk() {
        guard canHoldToAsk, !isHoldingToAsk else {
            return
        }

        isHoldingToAsk = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        coordinator.beginVoiceRequest()
    }

    private func endHoldingToAsk() {
        guard isHoldingToAsk else {
            return
        }

        isHoldingToAsk = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        coordinator.endVoiceRequest()
    }

    private func playStateHaptic(for state: EchoraState) {
        switch state {
        case .guiding, .narrating:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .found:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        default:
            break
        }
    }

    private func markFoundWithMagicTap() {
        switch coordinator.state {
        case .guiding, .narrating:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            coordinator.markFound()
        default:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}
