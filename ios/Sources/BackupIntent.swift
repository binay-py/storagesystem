// A "Back Up to Sanduk" action for the Shortcuts app. Use it in a Personal
// Automation such as "When charger is connected" or "When I arrive home" with
// "Run Immediately" on: it is the most dependable way to get regular backups,
// because iOS decides on its own when ordinary background tasks run.

import AppIntents

struct BackUpNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Back Up to Sanduk"
    static let description = IntentDescription("Encrypts and uploads new photos and videos to your Sanduk chest.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Shortcuts gives an action about 30 s in the background; stop starting new
        // items before then. Anything cut off resumes on the next run.
        await BackupEngine.shared.run(trigger: .shortcut, deadline: Date().addingTimeInterval(22))
        BackgroundJobs.schedule()
        return .result(dialog: IntentDialog(stringLiteral: BackupEngine.shared.lastMessage ?? "done"))
    }
}

struct SandukShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BackUpNowIntent(),
                    phrases: ["Back up \(.applicationName)", "Back up photos with \(.applicationName)"],
                    shortTitle: "Back Up",
                    systemImageName: "lock.icloud")
    }
}
