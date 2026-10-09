import SwiftUI

@main
struct EchoraApp: App {
    @StateObject private var coordinator: EchoraCoordinator

    init() {
        let environment = AppEnvironment.make(flags: ServiceFlags.current())
        _coordinator = StateObject(wrappedValue: EchoraCoordinator(environment: environment))
    }

    var body: some Scene {
        WindowGroup {
            OperatorView()
                .environmentObject(coordinator)
        }
    }
}
