import AppKit
import MenuBarExtraAccess
import SwiftUI

struct ContentView: View {
    @ObservedObject var serverController: ServerController
    @Binding var isEnabled: Bool
    @Binding var isMenuPresented: Bool
    @Environment(\.openSettings) private var openSettings
    @AppStorage(MessagesSendingMode.storageKey)
    private var sendingModeRaw = MessagesSendingMode.defaultValue.rawValue

    private let aboutWindowController: AboutWindowController

    /// Mirrors the same `MenuBarIconAppearance` the menu-bar glyph uses, so the
    /// status surface below appears/disappears in exact agreement with the
    /// amber indicator rather than deriving its own second notion of "active."
    private var isAutomaticSendingActive: Bool {
        MenuBarIconAppearance.resolve(
            isServerEnabled: isEnabled,
            sendingMode: MessagesSendingMode.decode(sendingModeRaw)
        )
        .isAutomaticSendingActive
    }

    /// Pause writes the existing global Sending mode back to Ask Before
    /// Sending — the same storage key `GeneralSettingsView` reads and writes.
    /// There is no separate paused flag or second state machine.
    private func pauseAutomaticSending() {
        sendingModeRaw = MessagesSendingMode.askBeforeSending.rawValue
    }

    private var serviceConfigs: [ServiceConfig] {
        serverController.computedServiceConfigs
    }

    private var serviceBindings: [String: Binding<Bool>] {
        Dictionary(
            uniqueKeysWithValues: serviceConfigs.map {
                ($0.id, $0.binding)
            }
        )
    }

    init(
        serverManager: ServerController,
        isEnabled: Binding<Bool>,
        isMenuPresented: Binding<Bool>
    ) {
        self.serverController = serverManager
        self._isEnabled = isEnabled
        self._isMenuPresented = isMenuPresented
        self.aboutWindowController = AboutWindowController()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Enable MCP Server")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.top, 2)
            .padding(.horizontal, 14)
            .onChange(of: isEnabled, initial: true) {
                Task {
                    await serverController.setEnabled(isEnabled)
                }
            }

            if isAutomaticSendingActive {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()

                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                        Text("Automatic sending is on")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                    }

                    Text(
                        "Eligible existing-conversation text and attachment sends can submit without asking. A new recipient still opens Messages for you to review and send."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Button("Pause Automatic Sending") {
                        pauseAutomaticSending()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
                }
                .padding(.top, 8)
                .padding(.bottom, 4)
                .padding(.horizontal, 14)
            }

            if isEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()

                    Text("Services")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .opacity(isEnabled ? 1.0 : 0.4)
                        .padding(.horizontal, 14)

                    ForEach(serviceConfigs) { config in
                        ServiceToggleView(config: config)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 4)
                .padding(.horizontal, 2)
                .onChange(of: serviceConfigs.map { $0.binding.wrappedValue }, initial: true) {
                    Task {
                        await serverController.updateServiceBindings(serviceBindings)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.easeInOut(duration: 0.3), value: isEnabled)
            }

            VStack(alignment: .leading, spacing: 2) {
                Divider()

                MenuButton("Configure Claude Desktop", isMenuPresented: $isMenuPresented) {
                    ClaudeDesktop.showConfigurationPanel()
                }

                MenuButton("Copy server command to clipboard", isMenuPresented: $isMenuPresented) {
                    let command = Bundle.main.bundleURL
                        .appendingPathComponent("Contents/MacOS/imcp-server")
                        .path

                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(command, forType: .string)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 2)
            .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 2) {
                Divider()

                MenuButton("Settings...", isMenuPresented: $isMenuPresented) {
                    // Closing the key window directly (rather than only clearing
                    // `isMenuPresented`) is required because MenuBarExtraAccess 1.2.1
                    // reconciles `isMenuPresented` through a Scene-level `.onChange`,
                    // which doesn't dismiss the panel synchronously. Re-verify this
                    // dismissal manually if MenuBarExtraAccess is ever upgraded.
                    NSApp.keyWindow?.close()
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }

                MenuButton("About iMCP", isMenuPresented: $isMenuPresented) {
                    aboutWindowController.showWindow(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }

                MenuButton("Quit", isMenuPresented: $isMenuPresented) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.bottom, 2)
            .padding(.horizontal, 2)
        }
        .padding(.vertical, 6)
        .background(Material.thick)
    }
}

private struct MenuButton: View {
    @Environment(\.isEnabled) private var isEnabled

    private let title: String
    private let action: () -> Void
    @Binding private var isMenuPresented: Bool
    @State private var isHighlighted: Bool = false
    @State private var isPressed: Bool = false

    init<S>(
        _ title: S,
        isMenuPresented: Binding<Bool>,
        action: @escaping () -> Void
    ) where S: StringProtocol {
        self.title = String(title)
        self._isMenuPresented = isMenuPresented
        self.action = action
    }

    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(.primary.opacity(isEnabled ? 1.0 : 0.4))
                .multilineTextAlignment(.leading)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)

            Spacer()
        }
        .contentShape(Rectangle())
        .allowsHitTesting(isEnabled)
        .onTapGesture {
            guard isEnabled else { return }

            Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isPressed = true
                }

                try? await Task.sleep(for: .milliseconds(100))

                withAnimation(.easeInOut(duration: 0.1)) {
                    isPressed = false
                }

                isMenuPresented = false
                action()
            }
        }
        .frame(height: 18)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    isPressed
                        ? Color.accentColor
                        : isHighlighted ? Color.accentColor.opacity(0.7) : Color.clear
                )
        )
        .onHover { state in
            guard isEnabled else { return }
            isHighlighted = state
        }
        .onChange(of: isEnabled) { _, newValue in
            if !newValue {
                isHighlighted = false
                isPressed = false
            }
        }
    }
}
