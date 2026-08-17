import AppKit
import Foundation

/// One Allowed Folders row as Settings displays it.
struct AttachmentFolderGrantRow: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    /// Location text for display only. Never logged; Settings is the one surface allowed
    /// to show it, mirroring the existing attachment confirmation's own name/type/size
    /// exception to the no-private-data-outside-authorization-surfaces rule.
    let locationText: String
    let isBroken: Bool
}

/// Drives the inline Attachments / Allowed Folders section of Settings.
///
/// Owns no security decisions itself: it is a thin, `@MainActor` presentation layer over
/// `AllowedFolderGrantStoring`, which is exactly what `message_send_attachment` also reads
/// through `AllowedFolderGrantResolving`. Both read the same persisted `UserDefaults` state,
/// so a folder added here is immediately usable by the tool and vice versa.
@MainActor
final class AttachmentFolderGrantsController: ObservableObject {
    @Published private(set) var rows: [AttachmentFolderGrantRow] = []

    private let store: any AllowedFolderGrantStoring

    init(store: any AllowedFolderGrantStoring = UserDefaultsAllowedFolderGrantStore()) {
        self.store = store
        refresh()
    }

    func refresh() {
        rows = store.listGrants().map { grant in
            let resolvedURL = try? AllowedFolderBookmark.resolve(grant.bookmarkData)
            return AttachmentFolderGrantRow(
                id: grant.id,
                displayName: grant.displayName,
                locationText: resolvedURL?.path ?? grant.displayName,
                isBroken: resolvedURL == nil
            )
        }
    }

    /// Opens the standard macOS folder picker directly, for exactly one directory and no
    /// files, with no intermediate preset menu.
    func addFolder() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "Select a folder to allow for Messages attachments"
        panel.prompt = "Allow Folder"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.addGrant(for: url)
        } catch {
            presentFailureAlert(
                title: "Couldn't Allow Folder",
                message: "iMCP could not save access to that folder."
            )
        }
        refresh()
    }

    func remove(id: UUID) {
        store.removeGrant(id: id)
        refresh()
    }

    /// Reauthorizes one broken grant by letting the user pick a folder again, replacing
    /// that row's bookmark in place so its Settings row identity is stable.
    func reauthorize(id: UUID) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.message = "Select the folder again to restore access"
        panel.prompt = "Allow Folder"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.replaceGrant(id: id, with: url)
        } catch {
            presentFailureAlert(
                title: "Couldn't Reauthorize Folder",
                message: "iMCP could not save access to that folder."
            )
        }
        refresh()
    }

    func showInFinder(id: UUID) {
        guard let grant = store.listGrants().first(where: { $0.id == id }),
            let url = try? AllowedFolderBookmark.resolve(grant.bookmarkData)
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func presentFailureAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
