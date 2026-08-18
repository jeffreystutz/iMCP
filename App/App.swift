import MenuBarExtraAccess
import SwiftUI

@main
struct App: SwiftUI.App {
    @StateObject private var serverController = ServerController()
    @AppStorage("isEnabled") private var isEnabled = true
    @AppStorage(MessagesSendingMode.storageKey)
    private var sendingModeRaw = MessagesSendingMode.defaultValue.rawValue
    @State private var isMenuPresented = false

    private var menuBarIconAppearance: MenuBarIconAppearance {
        MenuBarIconAppearance.resolve(
            isServerEnabled: isEnabled,
            sendingMode: MessagesSendingMode.decode(sendingModeRaw)
        )
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(
                serverManager: serverController,
                isEnabled: $isEnabled,
                isMenuPresented: $isMenuPresented
            )
        } label: {
            MenuBarIconView(appearance: menuBarIconAppearance)
        }
        .menuBarExtraStyle(.window)
        .menuBarExtraAccess(isPresented: $isMenuPresented)

        Settings {
            SettingsView(serverController: serverController)
        }

        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}
