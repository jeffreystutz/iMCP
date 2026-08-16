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
    @AppStorage(MessagesAutomaticSendPolicy.storageKey)
    private var automaticSendPolicyData = MessagesAutomaticSendPolicy.defaultValue.encoded()
    @AppStorage(PhoneNumberRegionSetting.storageKey)
    private var phoneNumberRegion = PhoneNumberRegionSetting.defaultValue.rawValue
    @State private var showingResetAlert = false
    @State private var selectedClients = Set<String>()
    @State private var showingAutomaticSendWarning = false
    @State private var pendingAutomaticSendPolicyData: Data?

    private var automaticSendPolicy: MessagesAutomaticSendPolicy {
        MessagesAutomaticSendPolicy.decode(automaticSendPolicyData)
    }

    /// Applies a policy change directly, unless it is the sensitive "no category was
    /// automatic, now at least one is" transition, in which case it stages the change and
    /// shows one warning instead of applying it — regardless of which control (an
    /// individual toggle or "Allow Everything Automatically") triggered the transition, so
    /// the warning appears at most once per transition rather than once per checkbox.
    private func requestAutomaticSendPolicyChange(
        _ mutate: (inout MessagesAutomaticSendPolicy) -> Void
    ) {
        var updated = automaticSendPolicy
        let wasAnyAutomatic = updated.isAnyCategoryAutomatic
        mutate(&updated)
        if updated.isAnyCategoryAutomatic && !wasAnyAutomatic {
            pendingAutomaticSendPolicyData = updated.encoded()
            showingAutomaticSendWarning = true
        } else {
            automaticSendPolicyData = updated.encoded()
        }
    }

    private var trustedClients: [String] {
        serverController.getTrustedClients()
    }

    var body: some View {
        Form {
            Section("Message Sending") {
                Picker(
                    "Send confirmation",
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
                    "How iMCP confirms a message sent to a conversation you already have, when confirmation is required. Automatic uses an MCP form when the client advertises support; otherwise iMCP shows the confirmation. Choose iMCP app for clients that do not visibly support form elicitation. Whether confirmation is required at all for a given kind of message is controlled separately, in Automatic Sending below."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(
                    "This setting does not apply to a recipient you have no conversation with. Those open a Messages compose window that you review, may edit, and send yourself."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Automatic Sending") {
                Text(
                    "By default, iMCP asks you to confirm before sending. Turning on a category below applies to every connected MCP client: any of them may then submit that kind of message without asking each time. This does not change how a destination is resolved or verified, and does not apply to a new recipient, which always opens a Messages compose window you complete yourself."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(MessagesAutomaticSendCategory.allCases) { category in
                    Toggle(
                        category.title,
                        isOn: Binding(
                            get: { automaticSendPolicy.isAutomatic(category) },
                            set: { isAutomatic in
                                requestAutomaticSendPolicyChange {
                                    $0.setAutomatic(isAutomatic, for: category)
                                }
                            }
                        )
                    )
                }

                HStack {
                    Button("Allow Everything Automatically") {
                        requestAutomaticSendPolicyChange { $0.allowEverythingAutomatically() }
                    }
                    .disabled(automaticSendPolicy.isEveryCategoryAutomatic)

                    Button("Require Confirmation for Everything") {
                        automaticSendPolicyData =
                            MessagesAutomaticSendPolicy.confirmationRequiredForEverything
                            .encoded()
                    }
                    .disabled(!automaticSendPolicy.isAnyCategoryAutomatic)
                }
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
        .alert("Allow Automatic Sending?", isPresented: $showingAutomaticSendWarning) {
            Button("Cancel", role: .cancel) {
                pendingAutomaticSendPolicyData = nil
            }
            Button("Allow Automatically") {
                if let pendingAutomaticSendPolicyData {
                    automaticSendPolicyData = pendingAutomaticSendPolicyData
                }
                pendingAutomaticSendPolicyData = nil
            }
        } message: {
            Text(
                "Connected MCP clients will be able to send eligible Messages operations without asking each time. You can turn this off again at any time."
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
