import SwiftUI

@main
struct DictKBApp: App {
    @State private var model = ModelService.shared
    @State private var server = BridgeServer.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(server)
                .onOpenURL { url in
                    guard url.scheme == "dictkb" else { return }
                    server.handleOpen(url)
                }
                .task { server.start() }
        }
    }
}
