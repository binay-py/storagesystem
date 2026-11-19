import Photos
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var engine: BackupEngine

    var body: some View {
        if engine.configured, let server = Keychain.get("server"), let secret = Keychain.get("secret") {
            TabView {
                ChestWebView(server: server, secret: secret)
                    .background(Color(red: 0.075, green: 0.071, blue: 0.082).ignoresSafeArea())
                    .tabItem { Label("Chest", systemImage: "photo.on.rectangle") }
                NavigationStack { MainView() }
                    .tabItem { Label("Backup", systemImage: "lock.icloud") }
            }
            .tint(Color(red: 0.79, green: 0.6, blue: 0.23))
        } else {
            NavigationStack { SetupView() }
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
