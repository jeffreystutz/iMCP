import SwiftUI

struct SettingsView: View {
    @ObservedObject var serverController: ServerController
    @State private var selectedSection: SettingsSection? = .general

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "General"

        var id: String { self.rawValue }

        var icon: String {
            switch self {
            case .general: return "gear"
            }
        }
    }

    var body: some View {
        NavigationView {
            List(
                selection: .init(
                    get: { selectedSection },
                    set: { section in
                        selectedSection = section
                    }
                )
            ) {
                Section {
                    ForEach(SettingsSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.icon)
                            .tag(section)
                    }
                }
            }

            if let selectedSection {
                switch selectedSection {
                case .general:
                    GeneralSettingsView(serverController: serverController)
                        .navigationTitle("General")
                        .formStyle(.grouped)
                }
            } else {
                Text("Select a category")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            Text("")
        }
        .task {
            let window = NSApplication.shared.keyWindow
            window?.toolbarStyle = .unified
            window?.toolbar?.displayMode = .iconOnly
        }
        .onAppear {
            if selectedSection == nil, let firstSection = SettingsSection.allCases.first {
                selectedSection = firstSection
            }
        }
    }

}

struct GeneralSettingsView: View {
    @ObservedObject var serverController: ServerController
    @AppStorage(MessagesSendConfirmationMode.storageKey)
    private var sendConfirmationMode = MessagesSendConfirmationMode.defaultValue.rawValue
    @AppStorage(MessagesSendingMode.storageKey)
    private var sendingMode = MessagesSendingMode.defaultValue.rawValue
    @AppStorage(PhoneNumberRegionSetting.storageKey)
    private var phoneNumberRegion = PhoneNumberRegionSetting.defaultValue.rawValue
    @State private var showingResetAlert = false
    @State private var selectedClients = Set<String>()
    @State private var showingSendAutomaticallyWarning = false

    /// Applies a sending-mode change directly, unless it is the transition from Ask
    /// Before Sending to Send Automatically, in which case it stages the change and
    /// shows one warning instead of applying it immediately. Switching back to Ask
    /// Before Sending never warns, since that can only make behavior safer.
    private func requestSendingModeChange(_ newMode: MessagesSendingMode) {
        if newMode == .sendAutomatically
            && MessagesSendingMode.decode(sendingMode) == .askBeforeSending
        {
            showingSendAutomaticallyWarning = true
        } else {
            sendingMode = newMode.rawValue
        }
    }

    private var trustedClients: [String] {
        serverController.getTrustedClients()
    }

    var body: some View {
        Form {
            Section("Message Sending") {
                Picker(
                    "Sending",
                    selection: Binding(
                        get: { MessagesSendingMode.decode(sendingMode) },
                        set: { requestSendingModeChange($0) }
                    )
                ) {
                    ForEach(MessagesSendingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Text(
                    "Ask Before Sending is the safe default: iMCP confirms before submitting a message to a conversation you already have. Send Automatically applies to every connected MCP client, letting any of them submit an eligible message without asking each time. Neither changes how a destination is resolved or verified."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if MessagesSendingMode.decode(sendingMode) == .askBeforeSending {
                    Picker(
                        "Confirmation method",
                        selection: Binding(
                            get: { MessagesSendConfirmationMode.decode(sendConfirmationMode) },
                            set: { sendConfirmationMode = $0.rawValue }
                        )
                    ) {
                        ForEach(MessagesSendConfirmationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    Text(
                        "How iMCP presents that confirmation. Best available uses an MCP form when the client advertises support, otherwise iMCP shows the confirmation. Choose iMCP app for clients that do not visibly support form elicitation."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Text(
                    "Neither setting applies to a recipient you have no conversation with. Those open a Messages compose window that you review, may edit, and send yourself."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Phone Number Region") {
                Picker(
                    "Region",
                    selection: Binding(
                        get: { PhoneNumberRegionSetting.decode(phoneNumberRegion) },
                        set: { phoneNumberRegion = $0.rawValue }
                    )
                ) {
                    Text("System Region").tag(PhoneNumberRegionSetting.system)
                    Divider()
                    ForEach(PhoneNumberRegionCatalog.regionCodes, id: \.self) { regionCode in
                        Text(PhoneNumberRegionCatalog.displayName(for: regionCode))
                            .tag(PhoneNumberRegionSetting.override(regionCode))
                    }
                }

                Text(
                    "The region iMCP uses to interpret a locally formatted stored phone number as an exact identity. System Region follows the Mac's current region automatically. An already international number (starting with +) is unaffected by this setting."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Trusted Clients")
                            .font(.headline)
                        Spacer()
                        if !trustedClients.isEmpty {
                            Button("Remove All") {
                                showingResetAlert = true
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                    }

                    Text("Clients that automatically connect without approval.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                if trustedClients.isEmpty {
                    HStack {
                        Text("No trusted clients")
                            .foregroundStyle(.secondary)
                            .italic()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else {
                    List(trustedClients, id: \.self, selection: $selectedClients) { client in
                        HStack {
                            Text(client)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                        }
                        .contextMenu {
                            Button("Remove Client", role: .destructive) {
                                serverController.removeTrustedClient(client)
                            }
                        }
                    }
                    .frame(minHeight: 100, maxHeight: 200)
                    .onDeleteCommand {
                        for clientID in selectedClients {
                            serverController.removeTrustedClient(clientID)
                        }
                        selectedClients.removeAll()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Send Automatically?", isPresented: $showingSendAutomaticallyWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Send Automatically") {
                sendingMode = MessagesSendingMode.sendAutomatically.rawValue
            }
        } message: {
            Text(
                "All connected MCP clients will be able to submit an eligible existing-conversation Messages send without asking each time. You can switch back to Ask Before Sending at any time."
            )
        }
        .alert("Remove All Trusted Clients", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove All", role: .destructive) {
                serverController.resetTrustedClients()
                selectedClients.removeAll()
            }
        } message: {
            Text(
                "This will remove all trusted clients. They will need to be approved again when connecting."
            )
        }
    }
}
