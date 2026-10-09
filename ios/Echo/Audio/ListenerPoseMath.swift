import Foundation
import simd

// SCAFFOLD STUB (contracts v1). Seoyeon owns this file and replaces the body
// with the full Part 4.4 implementation (head yaw/pitch) plus unit tests.
// It exists now only so EchoCoordinator's real-time loop compiles on main.
enum ListenerPoseMath {
    static func compose(body: BodyPose, head: HeadRotation, rig: ListenerRig) -> ListenerPose {
        let worldUp = SIMD3<Float>(0, 1, 0)

        let position: SIMD3<Float>
        switch rig {
        case .standInFront(let backOffsetMeters, let upOffsetMeters):
            position = body.position - body.forward * backOffsetMeters + worldUp * upOffsetMeters
        case .chestMount(let upOffsetMeters):
            position = body.position + worldUp * upOffsetMeters
        }

        // TODO(Seoyeon): apply head.yawRadians and head.pitchRadians.
        return ListenerPose(position: position, forward: body.forward, up: worldUp)
    }
}
