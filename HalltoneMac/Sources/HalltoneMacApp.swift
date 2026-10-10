import SwiftUI

@main
struct HalltoneMacApp: App {
    @StateObject private var model = SenderModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(systemName: model.isStreaming ? "ear.fill" : "ear")
        }
        .menuBarExtraStyle(.window)
    }
}
