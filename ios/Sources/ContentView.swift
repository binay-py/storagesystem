import Photos
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var engine: BackupEngine

    var body: some View {
        NavigationStack {
            if engine.configured { MainView() } else { SetupView() }
        }
    }
}

// MARK: - setup

private struct SetupView: View {
    @EnvironmentObject private var engine: BackupEngine
    @State private var server = ""
    @State private var secret = ""
    @State private var busy = false
    @State private var error: String?
    @State private var emptyWarning = false

    var body: some View {
        Form {
            Section {
                TextField("https://sanduk.you.workers.dev", text: $server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: { Text("Your Sanduk address") }

            Section {
                SecureField("Chest key", text: $secret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: { Text("Chest key") } footer: {
                Text("The same key you unlock the web app with. It stays in this iPhone's Keychain and is never sent anywhere.")
            }

            if let error { Section { Text(error).foregroundStyle(.red) } }

            Section {
                Button(busy ? "Checking…" : "Connect") { Task { await connect() } }
                    .disabled(busy || server.isEmpty || secret.isEmpty)
            }
        }
        .navigationTitle("Sanduk Backup")
        .alert("This chest is empty", isPresented: $emptyWarning) {
            Button("Use it anyway") { engine.save(server: server, secret: secret) }
            Button("Check the key", role: .cancel) {}
        } message: {
            Text("A key with a typo opens a new, empty chest. If you already have photos in Sanduk, the key is probably wrong.")
        }
    }

    private func connect() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let count = try await engine.check(server: server, secret: secret)
            if count == 0 { emptyWarning = true } else { engine.save(server: server, secret: secret) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - main

private struct MainView: View {
    @EnvironmentObject private var engine: BackupEngine
    @State private var photos = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var confirmSkip = false
    @State private var confirmForget = false

    var body: some View {
        Form {
            if photos != .authorized {
                Section {
                    Button("Allow access to all photos") { Task { await askPhotos() } }
                } footer: {
                    Text(photos == .limited
                         ? "Only some photos are shared with the app. Choose “Allow Full Access” in Settings so new photos are backed up too."
                         : "Needed to read your photos and videos.")
                }
            }

            Section("Backup") {
                LabeledContent("Backed up", value: "\(engine.doneCount) of \(engine.totalCount)")
                if engine.running {
                    VStack(alignment: .leading) {
                        Text(engine.status)
                        ProgressView(value: engine.progress)
                    }
                }
                if let last = engine.lastRun {
                    LabeledContent("Last run", value: last.formatted(.relative(presentation: .named)))
                }
                if let msg = engine.lastMessage {
                    Text(msg).font(.footnote).foregroundStyle(.secondary)
                }
                if engine.running {
                    Button("Stop", role: .destructive) { engine.cancel() }
                } else {
                    Button("Back up now") { Task { await engine.run() } }
                        .disabled(!BackupEngine.photosAllowed)
                }
            }

            Section {
                Toggle("Wi-Fi only", isOn: $engine.wifiOnly)
            } footer: {
                Text("Off lets it use mobile data too. Low Data Mode is treated like mobile data.")
            }

            Section("Automatic backup") {
                Text("iOS runs the backup on its own, mostly overnight while the phone charges on Wi-Fi. To make it reliable, add a Shortcuts automation:")
                Text("Shortcuts → Automation → New → Charger → Is Connected → Run Immediately → add “Back Up to Sanduk”.")
                    .font(.footnote)
                Text("Keep Background App Refresh on for this app, and don't swipe it away in the app switcher, or iOS stops waking it.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                Button("Only back up new photos from now on") { confirmSkip = true }
                Button("Re-check every photo") { engine.resetDone() }
                Button("Forget key on this iPhone", role: .destructive) { confirmForget = true }
            } footer: {
                Text("“Re-check” goes through the whole library again; photos already in the chest are recognised and skipped, not uploaded twice.")
            }
        }
        .navigationTitle("Sanduk Backup")
        .task {
            if photos == .notDetermined { await askPhotos() }
            engine.refreshCounts()
        }
        .refreshable { engine.refreshCounts() }
        .confirmationDialog("Skip everything already on this iPhone?", isPresented: $confirmSkip, titleVisibility: .visible) {
            Button("Skip existing \(engine.totalCount - engine.doneCount) items") { engine.markAllExistingDone() }
        }
        .confirmationDialog("Forget the chest key on this iPhone?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget key", role: .destructive) { engine.forget() }
        } message: {
            Text("Nothing in the chest is deleted. You'll need the key to connect again.")
        }
    }

    private func askPhotos() async {
        photos = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        engine.refreshCounts()
    }
}
