import SwiftUI

@main
struct SubtextApp: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}
