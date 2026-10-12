import Photos
import SwiftUI
import UIKit

struct BackupView: View {
    @State private var status = BackupStatus.shared
    @State private var enabled = BackupSettings.enabled
    @State private var wifiOnly = BackupSettings.wifiOnly
    @State private var videos = BackupSettings.includeVideos
    @State private var onlyNew = BackupSettings.since != nil
    @State private var since = BackupSettings.since ?? .now
    @State private var auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var confirmReset = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $enabled) {
                        Label("Fotos automatisch sichern", systemImage: "arrow.up.circle.fill")
                    }
                    .onChange(of: enabled) { _, on in Task { await setEnabled(on) } }
                } footer: {
                    Text("Neue Fotos und Videos landen in deinem privaten Bereich unter „Privat/iPhone/Jahr/Monat“. Live Photos bleiben Live Photos.")
                }

                if auth == .denied || auth == .restricted {
                    Section {
                        Label("Kein Zugriff auf deine Fotos", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Einstellungen öffnen") {
                            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                        }
                    }
                } else if auth == .limited {
                    Section {
                        Label("Nur ausgewählte Fotos freigegeben – es wird nur diese Auswahl gesichert.", systemImage: "info.circle")
                            .font(.footnote)
                    }
                }

                if enabled {
                    statusSection
                }

                Section("Optionen") {
                    Toggle("Nur im WLAN", isOn: $wifiOnly)
                        .onChange(of: wifiOnly) { _, v in BackupSettings.wifiOnly = v }
                    Toggle("Videos sichern", isOn: $videos)
                        .onChange(of: videos) { _, v in
                            BackupSettings.includeVideos = v
                            Task { await BackupEngine.shared.countPending() }
                        }
                    Toggle("Erst ab einem Datum", isOn: $onlyNew)
                        .onChange(of: onlyNew) { _, v in
                            BackupSettings.since = v ? Calendar.current.startOfDay(for: since) : nil
                            Task { await BackupEngine.shared.countPending() }
                        }
                    if onlyNew {
                        DatePicker("Ab", selection: $since, in: ...Date.now, displayedComponents: .date)
                            .onChange(of: since) { _, v in
                                BackupSettings.since = Calendar.current.startOfDay(for: v)
                                Task { await BackupEngine.shared.countPending() }
                            }
                    }
                }

                Section {
                    Button("Abgleich zurücksetzen", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("iOS sichert im Hintergrund vor allem nachts, wenn das iPhone lädt und im WLAN ist. Den ersten großen Abgleich am besten mit geöffneter App und Ladekabel machen.")
                }
            }
            .navigationTitle("Backup")
            .updateBanner()
            .confirmationDialog("Abgleich zurücksetzen?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Zurücksetzen", role: .destructive) {
                    BackupLog.current()?.reset()
                    status.backedUp = 0
                    Task { await BackupEngine.shared.countPending() }
                }
            } message: {
                Text("Die App prüft dann alle Fotos erneut. Was schon auf dem Server liegt, wird übersprungen und nicht doppelt hochgeladen.")
            }
            .task { await BackupEngine.shared.countPending() }
            .onChange(of: scenePhase) { _, p in
                if p == .active { auth = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
            }
            // Bildschirm anlassen, solange bei geöffneter App gesichert wird
            .onChange(of: status.running) { _, running in UIApplication.shared.isIdleTimerDisabled = running }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            if status.running {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Sichere …").bold()
                        Spacer()
                        Text("\(status.processed) von \(status.total)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(status.processed), total: Double(max(status.total, 1)))
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        HStack {
                            if let speed = status.speed {
                                Text("\(Format.bytes(Int64(speed)))/s")
                            }
                            Spacer()
                            Text(Format.bytes(status.bytes) + " hochgeladen")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    ForEach(status.current, id: \.self) { name in
                        Label(name, systemImage: "arrow.up.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
            } else {
                LabeledContent("Gesichert", value: "\(status.backedUp)")
                LabeledContent("Ausstehend", value: status.pending.map(String.init) ?? "…")
                if let last = status.lastRun {
                    LabeledContent("Letzter Abgleich", value: Format.relative(last))
                }
            }

            if status.paused {
                Label("Pausiert", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
                Button {
                    Task {
                        await BackupEngine.shared.resume()
                        BackgroundBackup.schedule()
                        BackgroundBackup.startManual()
                    }
                } label: {
                    Label("Fortsetzen", systemImage: "play.fill")
                }
            } else {
                if !status.running {
                    Button {
                        BackgroundBackup.startManual()
                    } label: {
                        Label("Jetzt sichern", systemImage: "arrow.clockwise")
                    }
                    .disabled(auth != .authorized && auth != .limited)
                }
                Button {
                    Task {
                        await BackupEngine.shared.pause()
                        BackgroundBackup.schedule()
                    }
                } label: {
                    Label("Pausieren", systemImage: "pause.fill")
                }
            }

            if status.failed > 0 {
                Label("\(status.failed) Fotos konnten nicht gesichert werden", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
            if let err = status.lastError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func setEnabled(_ on: Bool) async {
        if on {
            if auth == .notDetermined {
                auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            guard auth == .authorized || auth == .limited else {
                enabled = false
                return
            }
            BackupSettings.enabled = true
            await BackupEngine.shared.resume()
            PhotoLibraryWatcher.shared.start()
            BackgroundBackup.schedule()
            await BackupEngine.shared.countPending()
            BackgroundBackup.startManual()
        } else {
            BackupSettings.enabled = false
            await BackupEngine.shared.cancel()
            BackgroundBackup.schedule()
        }
    }
}
