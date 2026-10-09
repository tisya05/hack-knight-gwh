import SwiftUI

@main
struct EchoApp: App {
    @StateObject private var coordinator: EchoCoordinator

    init() {
        let environment = AppEnvironment.make(flags: ServiceFlags.current())
        _coordinator = StateObject(wrappedValue: EchoCoordinator(environment: environment))
    }

    var body: some Scene {
        WindowGroup {
            OperatorView()
                .environmentObject(coordinator)
        }
    }
}
