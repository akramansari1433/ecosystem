import SwiftUI

@main
struct EcosystemApp: App {
    @State private var appState: AppState
    @State private var manager: ConnectionManager

    init() {
        let state = AppState.shared
        _appState = State(initialValue: state)
        let manager = ConnectionManager.shared
        _manager = State(initialValue: manager)
        // The unit-test runner launches this app as its host; starting the real
        // connection stack there would delete the LIVE app's keychain and battle
        // it for the phone. Only run for real launches.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            manager.start()
        }
        AppServices.manager = manager
    }

    var body: some Scene {
        MenuBarExtra("Ecosystem", systemImage: appState.menuBarSymbol) {
            MenuContent(manager: manager)
                .environment(appState)
        }
        .menuBarExtraStyle(.window)

        Window("Phone Files", id: "phone-files") {
            FileBrowserView(model: manager.files)
                .environment(appState)
        }
        .defaultSize(width: 640, height: 440)

        Window("Phone Camera", id: "phone-camera") {
            CameraWindow(session: manager.camera)
                .environment(appState)
        }
        .defaultSize(width: 720, height: 460)

        Window("Phone Screen", id: "phone-mirror") {
            MirrorWindow(session: manager.mirror)
                .environment(appState)
        }
        .defaultSize(width: 320, height: 660)
    }
}
