import Photos
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var engine: BackupEngine

    var body: some View {
        if engine.configured, let server = Keychain.get("server"), let secret = Keychain.get("secret") {
            LibraryScreen(server: server, secret: secret)
        } else {
            NavigationStack { SetupView() }.tint(sandukGold)
        }
    }
}

/// The library fills the screen with one tab bar (the page's own: Photos,
/// Collections, Search, Backup). Backup opens the native backup screen as a sheet.
private struct LibraryScreen: View {
    @EnvironmentObject private var engine: BackupEngine
    let server: String
    let secret: String
    @State private var showBackup = false
    @State private var pageHasBackupTab = true

    var body: some View {
        ChestWebView(server: server, secret: secret,
                     onBackup: { showBackup = true },
                     onBackupTab: { pageHasBackupTab = $0 })
            .ignoresSafeArea()
            .background(Color(.systemBackground).ignoresSafeArea())
            .overlay(alignment: .topTrailing) {
                // an older web app has no Backup tab; keep the screen reachable
                if !pageHasBackupTab {
                    Button { showBackup = true } label: {
                        Image(systemName: "icloud.and.arrow.up").font(.title3)
                            .padding(10).background(.regularMaterial, in: Circle())
                    }
                    .padding(.trailing, 12).padding(.top, 4)
                }
            }
            .sheet(isPresented: $showBackup) {
                NavigationStack {
                    MainView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { showBackup = false } }
                        }
                }
                .environmentObject(engine)
                .tint(sandukGold)
            }
            .task {
                // what the Backup tab used to do on launch
                if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
                    _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                    if engine.notifications { await BackupEngine.askNotificationPermission() }
                }
                engine.refreshCounts()
                engine.startWatching()
                await engine.run(trigger: .auto)
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
        .navigationTitle("Sanduk")
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
