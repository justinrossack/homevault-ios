import SwiftUI

struct StatusView: View {
    @State private var model = AppModel.shared
    @State private var storage: StorageOverview?
    @State private var disks: DiskStatus?
    @State private var diskSummary: DiskSummary?
    @State private var backups: BackupsResponse?
    @State private var error: String?
    @State private var confirmLogout = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "server.rack")
                            .font(.title)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(model.serverName).font(.headline)
                            Text(model.api?.baseURL.absoluteString ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle()
                            .fill(error == nil && storage != nil ? .green : (error == nil ? .gray : .red))
                            .frame(width: 10, height: 10)
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }

                if let s = storage { storageSection(s) }
                if model.isAdmin {
                    disksSection
                    backupsSection
                }

                Section("Konto") {
                    LabeledContent("Benutzer", value: model.me?.user?.name ?? Settings.username ?? "")
                    if model.isAdmin { LabeledContent("Rolle", value: "Administrator") }
                    Button("Abmelden", role: .destructive) { confirmLogout = true }
                }

                Section {
                    LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(UpdateChecker.currentBuild))")
                    if let exp = ProfileInfo.expiration {
                        LabeledContent("Installation gültig bis", value: exp.formatted(date: .long, time: .omitted))
                        if exp.timeIntervalSinceNow < 30 * 86400 && UpdateChecker.shared.available == nil {
                            Label("Die App muss bald neu installiert werden. Bitte beim Admin melden.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    if let release = UpdateChecker.shared.available {
                        Button {
                            UpdateChecker.shared.install()
                        } label: {
                            Label(release.date.map { "Update vom \($0) installieren" } ?? "Update installieren", systemImage: "arrow.down.app")
                        }
                    }
                    if let page = UpdateChecker.pagesURL {
                        Link(destination: page) {
                            Label("Installationsseite (für weitere Geräte)", systemImage: "link")
                        }
                    }
                } header: {
                    Text("App")
                }
            }
            .navigationTitle("Server")
            .updateBanner()
            .refreshable { await load() }
            .task { await load() }
            .confirmationDialog("Abmelden?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Abmelden", role: .destructive) { model.logout() }
            } message: {
                Text("Die automatische Foto-Sicherung wird dabei ausgeschaltet.")
            }
        }
    }

    private func storageSection(_ s: StorageOverview) -> some View {
        Section("Speicher") {
            if s.disk.total > 0 {
                let used = s.disk.total - s.disk.free
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Festplatte")
                        Spacer()
                        Text("\(Format.bytes(s.disk.free)) frei von \(Format.bytes(s.disk.total))")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                    ProgressView(value: Double(used), total: Double(s.disk.total))
                        .tint(s.warning ? .orange : .accentColor)
                }
                .padding(.vertical, 4)
                if s.warning {
                    Label("Der Speicher wird knapp", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if let quota = s.me.quota {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Mein Bereich")
                        Spacer()
                        Text("\(Format.bytes(s.me.used)) von \(Format.bytes(quota))").foregroundStyle(.secondary).font(.subheadline)
                    }
                    ProgressView(value: Double(min(s.me.used, quota)), total: Double(max(quota, 1)))
                }
            } else {
                LabeledContent("Mein Bereich", value: Format.bytes(s.me.used))
            }
            LabeledContent("Gemeinsam", value: "\(Format.bytes(s.shared.bytes)) · \(s.shared.files) Dateien")
            if let users = s.users, users.count > 1 {
                DisclosureGroup("Alle Benutzer") {
                    ForEach(users) { u in
                        LabeledContent(u.name, value: u.quota.map { "\(Format.bytes(u.usage.bytes)) / \(Format.bytes($0))" } ?? Format.bytes(u.usage.bytes))
                    }
                }
            }
            if let trash = s.trash, trash > 0 {
                LabeledContent("Papierkorb", value: Format.bytes(trash))
            }
        }
    }

    @ViewBuilder
    private var disksSection: some View {
        if let summary = diskSummary, summary.state != "none" {
            Section("Festplatten") {
                let (text, icon, color) = diskState(summary.state)
                Label(text, systemImage: icon).foregroundStyle(color)
                if let pool = disks?.pool {
                    if let size = pool.size, let used = pool.used {
                        LabeledContent("Spiegel", value: "\(Format.bytes(used)) von \(Format.bytes(size)) belegt")
                    }
                    ForEach(pool.devices) { d in
                        HStack {
                            Image(systemName: d.missing ? "xmark.circle.fill" : ((d.errors ?? 0) > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill"))
                                .foregroundStyle(d.missing ? .red : ((d.errors ?? 0) > 0 ? .orange : .green))
                            Text(d.missing ? "Platte fehlt" : (d.path ?? "Platte"))
                            Spacer()
                            if let model = disks?.disks?.first(where: { $0.path == d.path }) {
                                VStack(alignment: .trailing) {
                                    Text(model.model ?? "").font(.caption)
                                    if let t = model.smart?.temperature {
                                        Text("\(t) °C").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if pool.scrub?.running == true {
                        Label("Datenprüfung läuft", systemImage: "magnifyingglass")
                    } else if let last = pool.last_scrub {
                        LabeledContent("Letzte Datenprüfung", value: Format.date(last))
                    }
                }
            }
        }
    }

    private func diskState(_ s: String) -> (String, String, Color) {
        switch s {
        case "ok": ("Alle Platten in Ordnung", "checkmark.shield.fill", .green)
        case "warning": ("Warnung: Plattenfehler gemeldet", "exclamationmark.triangle.fill", .orange)
        case "degraded": ("Spiegel beschädigt – Platte fehlt oder defekt", "xmark.octagon.fill", .red)
        case "unreachable": ("Platten-Dienst nicht erreichbar", "questionmark.circle.fill", .orange)
        default: (s, "questionmark.circle", .secondary)
        }
    }

    @ViewBuilder
    private var backupsSection: some View {
        if let b = backups, !b.targets.isEmpty {
            Section("Server-Backups") {
                ForEach(b.targets) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(t.name).bold()
                            Spacer()
                            if b.running?.target_id == t.id {
                                ProgressView().controlSize(.small)
                            } else if let run = t.last_run {
                                Image(systemName: run.status == "ok" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(run.status == "ok" ? .green : .orange)
                            }
                        }
                        if let p = b.running, p.target_id == t.id, p.total_bytes > 0 {
                            ProgressView(value: Double(p.bytes), total: Double(p.total_bytes))
                            Text("\(p.part): \(Format.bytes(p.bytes)) von \(Format.bytes(p.total_bytes))").font(.caption).foregroundStyle(.secondary)
                        }
                        if let ok = t.last_success {
                            Text("Zuletzt erfolgreich: \(Format.date(ok))").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Noch nie erfolgreich").font(.caption).foregroundStyle(.orange)
                        }
                        if let run = t.last_run, run.status != "ok", let msg = run.message {
                            Text(msg).font(.caption).foregroundStyle(.red)
                        }
                        if let next = t.next_run {
                            Text("Nächster Lauf: \(Format.date(next))").font(.caption).foregroundStyle(.secondary)
                        } else if !t.enabled {
                            Text("Ausgeschaltet").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func load() async {
        guard let api = model.api else { return }
        async let update: Void = UpdateChecker.shared.check(force: true)
        await model.refreshMe()
        await update
        do {
            storage = try await api.get("api/storage")
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
            return
        }
        guard model.isAdmin else { return }
        async let summary: DiskSummary? = try? api.get("api/disks/summary")
        async let status: DiskStatus? = try? api.get("api/disks")
        async let backupList: BackupsResponse? = try? api.get("api/backups")
        diskSummary = await summary
        disks = await status
        backups = await backupList
    }
}
