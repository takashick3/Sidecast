import SwiftUI

@main
struct SidecastApp: App {
    @State private var controller = SidecastController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller)
        } label: {
            Image(systemName: controller.isActive ? "waveform" : "waveform.slash")
        }
        .menuBarExtraStyle(.window)
    }
}
