// The Backup tab: status card with progress ring, stats, settings and the
// steps that make background backup dependable.

import Photos
import SwiftUI

let sandukGold = Color(red: 0.79, green: 0.6, blue: 0.23)

struct MainView: View {
    @EnvironmentObject private var engine: BackupEngine
    @Environment(\.openURL) private var openURL
    @State private var photos = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var confirmSkip = false
    @State private var confirmForget = false

    var body: some View {
        List {
            if photos != .authorized {
                Section {
                    Button { Task { await askPhotos() } } label: {
                        Label("Allow access to all photos", systemImage: "exclamationmark.triangle.fill")
                    }
                    .tint(.orange)
                } footer: {
                    Text(photos == .limited
                         ? "Only some photos are shared with the app. Choose “Allow Full Access” so new photos are backed up too."
                         : "Needed to read your photos and videos.")
                }
            }

            Section { StatusCard() }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

            Section {
                HStack {
                    Stat(value: "\(engine.doneCount)", label: "Backed up")
                    Divider()
                    Stat(value: "\(engine.remaining)", label: "Waiting")
                    Divider()
                    Stat(value: ByteCountFormatter.string(fromByteCount: engine.uploadedBytes, countStyle: .file),
                         label: "Uploaded")
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle(isOn: $engine.autoBackup) {
                    Label("Auto backup", systemImage: "arrow.triangle.2.circlepath")
                }
                Toggle(isOn: $engine.wifiOnly) { Label("Wi-Fi only", systemImage: "wifi") }
                Toggle(isOn: $engine.includeVideos) { Label("Include videos", systemImage: "video") }
                Toggle(isOn: $engine.pauseOnLowPower) {
                    Label("Pause in Low Power Mode", systemImage: "battery.25")
                }
                Toggle(isOn: $engine.notifications) { Label("Notifications", systemImage: "bell.badge") }
            } header: { Text("Settings") } footer: {
                Text("Auto backup runs when you open the app, when you take a photo while it's open, and in the background, mostly overnight while charging.")
            }

            Section {
                Button {
                    if let u = URL(string: "shortcuts://") { openURL(u) }
                } label: {
                    Label("Set up a charging automation", systemImage: "bolt.fill")
                }
                Text("In Shortcuts: Automation → + → Charger → Is Connected → Run Immediately → add “Back Up to Sanduk”. Every time you plug in, new photos go to your chest.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) }
                } label: {
                    Label("Check Background App Refresh", systemImage: "gearshape")
                }
            } header: { Text("Make it reliable") } footer: {
                Text("Don't swipe the app away in the app switcher, or iOS stops waking it.")
            }

            Section {
                Button("Only back up new photos from now on") { confirmSkip = true }
                Button("Re-check every photo") { engine.resetDone() }
                Button("Forget key on this iPhone", role: .destructive) { confirmForget = true }
            } header: { Text("Advanced") } footer: {
                Text("“Re-check” goes through the whole library again. Photos already in the chest are recognised and skipped, not uploaded twice.")
            }
        }
        .navigationTitle("Backup")
        .tint(sandukGold)
        .task {
            if photos == .notDetermined { await askPhotos() }
            engine.refreshCounts()
            engine.startWatching()
            await engine.run(trigger: .auto) // e.g. right after first setup
        }
        .refreshable { engine.refreshCounts() }
        .confirmationDialog("Skip everything already on this iPhone?", isPresented: $confirmSkip, titleVisibility: .visible) {
            Button("Skip \(engine.remaining) existing items") { engine.markAllExistingDone() }
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
        engine.startWatching()
        if engine.notifications { await BackupEngine.askNotificationPermission() }
    }
}

// MARK: - status card

private struct StatusCard: View {
    @EnvironmentObject private var engine: BackupEngine

    private var fraction: Double {
        engine.totalCount == 0 ? 1 : Double(engine.doneCount) / Double(engine.totalCount)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(sandukGold.opacity(0.18), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(sandukGold, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut, value: fraction)
                    if let id = engine.currentAssetID {
                        AssetThumb(id: id)
                            .frame(width: 62, height: 62)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: engine.remaining == 0 ? "checkmark" : "lock.fill")
                            .font(.title.weight(.semibold))
                            .foregroundStyle(sandukGold)
                    }
                }
                .frame(width: 88, height: 88)

                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.running ? engine.status
                         : (engine.remaining == 0 ? "All backed up" : "\(engine.remaining) waiting"))
                        .font(.title3.weight(.semibold))
                    if engine.running {
                        Text("\(min(engine.passDone + 1, engine.passTotal)) of \(engine.passTotal)")
                            .font(.subheadline).foregroundStyle(.secondary)
                        ProgressView(value: engine.progress).tint(sandukGold)
                    } else {
                        Text("\(Int((fraction * 100).rounded(.down)))% of your library")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let last = engine.lastRun {
                            Text("Last run \(last.formatted(.relative(presentation: .named)))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            if let msg = engine.lastMessage, !engine.running {
                Text(msg)
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if engine.running {
                Button(role: .destructive) { engine.cancel() } label: {
                    Text("Stop").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                Button { Task { await engine.run(trigger: .manual) } } label: {
                    Label("Back up now", systemImage: "arrow.up.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(sandukGold)
                .controlSize(.large)
                .disabled(!BackupEngine.photosAllowed)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 16)
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Small thumbnail of a Photos asset, loaded on demand.
private struct AssetThumb: View {
    let id: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .task(id: id) { image = await Self.load(id) }
    }

    private static func load(_ id: String) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<UIImage?, Never>) in
            let o = PHImageRequestOptions()
            o.deliveryMode = .highQualityFormat // exactly one callback
            o.resizeMode = .fast
            o.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 200, height: 200),
                                                  contentMode: .aspectFill, options: o) { img, _ in
                c.resume(returning: img)
            }
        }
    }
}
