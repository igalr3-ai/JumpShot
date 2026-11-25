import SwiftUI

@main
struct JumpShotApp: App {
    init() { Key.registerDefaults() }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
