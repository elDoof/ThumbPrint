import SwiftUI

@main
struct ThumbPrintApp: App {
    /// Owned by the app rather than a view: the menu command and the launch
    /// check both reach it, and it has to outlive any single screen.
    @State private var updates = UpdateController()

    var body: some Scene {
        WindowGroup {
            ContentView(updates: updates)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}

            // Under the app menu, next to About — where every Mac app puts it.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkNow() }
                    .disabled(updates.isBusy)
            }
        }
    }
}
