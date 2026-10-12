import SwiftUI

@main
struct HalltonePhoneApp: App {
    @StateObject private var model = AppModel()

    init() { CrashReports.shared.start() }

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
        }
    }
}
