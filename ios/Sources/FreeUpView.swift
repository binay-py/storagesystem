// "Free up space": removes photos and videos from this iPhone that are safely in
// the chest. Every item is checked against the server's current list right
// before deleting, and iOS asks for confirmation itself. Removed items stay in
// Recently Deleted for 30 days.

import Photos
import SwiftUI

struct FreeUpView: View {
    @EnvironmentObject private var engine: BackupEngine
    @Environment(\.dismiss) private var dismiss
    @AppStorage("freeUp.keepDays") private var keepDays = 30
    @AppStorage("freeUp.keepFavorites") private var keepFavorites = true

    @State private var plan: BackupEngine.FreeUpPlan?
    @State private var loading = true
    @State private var working = false
    @State private var errorText: String?
    @State private var doneText: String?
    @State private var confirm = false

    private var count: Int { plan?.assets.count ?? 0 }
    private var size: String { ByteCountFormatter.string(fromByteCount: plan?.bytes ?? 0, countStyle: .file) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "iphone.and.arrow.forward")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(sandukGold)
                        if loading {
                            ProgressView("Checking your chest")
                        } else if let doneText {
                            Text(doneText).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                        } else if let errorText {
                            Text(errorText).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        } else if count == 0 {
                            Text("Nothing to remove right now").font(.title3.weight(.semibold))
                            Text("Items appear here once they are backed up and checked.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        } else {
                            Text(size).font(.largeTitle.weight(.bold))
                            Text("\(count) \(count == 1 ? "item is" : "items are") safely in your chest and can be removed from this iPhone.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }

                Section {
                    Picker("Recent photos", selection: $keepDays) {
                        Text("None").tag(0)
                        Text("Last 7 days").tag(7)
                        Text("Last 30 days").tag(30)
                        Text("Last 90 days").tag(90)
                    }
                    Toggle("Favorites", isOn: $keepFavorites)
                } header: { Text("Keep on this iPhone") }

                Section {
                    Button(role: .destructive) { confirm = true } label: {
                        HStack {
                            Spacer()
                            if working { ProgressView() } else { Text(count == 0 ? "Remove from iPhone" : "Remove \(count) from iPhone").bold() }
                            Spacer()
                        }
                    }
                    .disabled(count == 0 || working || loading)
                } footer: {
                    Text("iPhone asks you to confirm, and removed items stay in Recently Deleted for 30 days. If iCloud Photos is on, they are also removed from iCloud and your other Apple devices. They stay in your chest.")
                }

                if let unchecked = plan?.unchecked, unchecked > 0 {
                    Section {
                        Text("\(unchecked) older \(unchecked == 1 ? "backup hasn't" : "backups haven't") been double-checked yet, so \(unchecked == 1 ? "it isn't" : "they aren't") offered here. Tap Back up now and keep the app open; they are checked after the uploads.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Free up space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .tint(sandukGold)
            .task(id: "\(keepDays)-\(keepFavorites)") { await load() }
            .confirmationDialog("Remove \(count) items (\(size)) from this iPhone?", isPresented: $confirm,
                                titleVisibility: .visible) {
                Button("Remove from iPhone", role: .destructive) { Task { await remove() } }
            } message: {
                Text("They stay in your chest and in Recently Deleted for 30 days.")
            }
        }
    }

    private func load() async {
        loading = true
        errorText = nil
        do {
            plan = try await engine.freeUpPlan(keepDays: keepDays, keepFavorites: keepFavorites)
        } catch {
            plan = nil
            errorText = "Couldn't reach your chest, so nothing can be checked. Try again when you're online."
        }
        loading = false
    }

    private func remove() async {
        working = true
        defer { working = false }
        // check again right before deleting, in case something changed on the server
        guard let fresh = try? await engine.freeUpPlan(keepDays: keepDays, keepFavorites: keepFavorites),
              !fresh.assets.isEmpty else {
            await load(); return
        }
        let freed = ByteCountFormatter.string(fromByteCount: fresh.bytes, countStyle: .file)
        if await engine.delete(fresh.assets) {
            doneText = "Freed up \(freed)"
            plan = BackupEngine.FreeUpPlan(assets: [], bytes: 0, unchecked: fresh.unchecked)
        }
    }
}
