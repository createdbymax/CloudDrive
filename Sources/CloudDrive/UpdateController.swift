import AppKit
import Combine
import SwiftUI
import Sparkle

/// Updating never ejects a drive or interrupts transfers on the user's behalf.
@MainActor final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var hasDeferredInstall = false
    private let notice: (() -> Void)?
    var updater: SPUUpdater { controller.updater }
    private let canInstall: () -> Bool
    private var deferredInstall: (() -> Void)?
    private var observation: AnyCancellable?
    private var controller: SPUStandardUpdaterController!

    init(canInstall: @escaping () -> Bool, notice: (() -> Void)? = nil) {
        self.notice = notice
        self.canInstall = canInstall
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        // Source builds have no feed or public key until explicitly configured.
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              URL(string: feed)?.scheme == "https",
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != nil else { return }
        controller.updater.automaticallyDownloadsUpdates = false
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheck = $0 }
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard canInstall() else { showEjectNotice(); return }
        controller.checkForUpdates(nil)
    }

    func installDeferredUpdate() {
        guard canInstall() else { showEjectNotice(); return }
        let install = deferredInstall
        deferredInstall = nil
        hasDeferredInstall = false
        install?()
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard canInstall() else {
            throw NSError(domain: "CloudDrive.Update", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Eject CloudDrive before checking for updates. Pending uploads must finish first."])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallationIfNeeded(installHandler)
    }

    func postponeInstallationIfNeeded(_ installHandler: @escaping () -> Void) -> Bool {
        guard !canInstall() else { return false }
        deferredInstall = installHandler
        hasDeferredInstall = true
        showEjectNotice()
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        deferredInstall = nil
        hasDeferredInstall = false
    }

    private func showEjectNotice() {
        if let notice { notice(); return }
        let alert = NSAlert()
        alert.messageText = "Eject CloudDrive before updating"
        alert.informativeText = "Use Eject to finish pending uploads and close the Finder drive. Then choose Check for Updates… or Install Downloaded Update… again."
        alert.runModal()
    }
}

struct UpdateMenu: View {
    @ObservedObject var updates: UpdateController
    var body: some View {
        Button("Check for Updates…", action: updates.checkForUpdates).disabled(!updates.canCheck)
        if updates.hasDeferredInstall {
            Button("Install Downloaded Update…", action: updates.installDeferredUpdate)
        }
    }
}
