import SwiftUI

@main
struct HomeVaultApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundBackup.register()
        Downloads.cleanup()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await UpdateChecker.shared.check() }
                guard BackupSettings.enabled, AppModel.shared.api != nil else { return }
                PhotoLibraryWatcher.shared.start()
                BackgroundBackup.runWithGrace(.foreground)
            case .background:
                BackgroundBackup.schedule()
            default:
                break
            }
        }
    }
}

struct RootView: View {
    @State private var model = AppModel.shared

    var body: some View {
        if model.api == nil {
            LoginView()
        } else {
            TabView {
                PhotosView()
                    .tabItem { Label("Fotos", systemImage: "photo.on.rectangle") }
                FilesView()
                    .tabItem { Label("Dateien", systemImage: "folder") }
                BackupView()
                    .tabItem { Label("Backup", systemImage: "arrow.up.circle") }
                StatusView()
                    .tabItem { Label("Server", systemImage: "server.rack") }
            }
            .task { await model.refreshMe() }
        }
    }
}

extension View {
    /// „Update verfügbar“ unter der Titelleiste eines Tabs.
    func updateBanner() -> some View {
        modifier(UpdateBannerModifier())
    }
}

private struct UpdateBannerModifier: ViewModifier {
    @State private var updates = UpdateChecker.shared

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let release = updates.available, !updates.dismissed {
                    UpdateBanner(release: release) { updates.dismissed = true }
                }
            }
            .animation(.default, value: updates.dismissed)
    }
}

struct UpdateBanner: View {
    let release: UpdateChecker.Release
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(release.date.map { "Update vom \($0)" } ?? "Update verfügbar").font(.subheadline.bold())
                if let notes = release.notes, !notes.isEmpty {
                    Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Button("Installieren") { UpdateChecker.shared.install() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.secondary)
            }
            .accessibilityLabel("Später")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct LoginView: View {
    @State private var server = Settings.server.flatMap { URL(string: $0) }.map { u in
        u.port == 8080 ? (u.host ?? "") : "\(u.host ?? ""):\(u.port ?? 80)"
    } ?? ""
    @State private var username = Settings.username ?? ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("z. B. 192.168.1.10", text: $server)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("Die Adresse, unter der du homevault im Browser öffnest. Ohne Angabe wird Port 8080 verwendet.")
                }
                Section("Anmeldung") {
                    TextField("Benutzername", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Passwort", text: $password)
                        .textContentType(.password)
                        .onSubmit(login)
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button(action: login) {
                        HStack {
                            Spacer()
                            if busy { ProgressView() } else { Text("Anmelden").bold() }
                            Spacer()
                        }
                    }
                    .disabled(busy || server.isEmpty || username.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("homevault")
            #if DEBUG
            // Simulator-Tests: Felder per Umgebungsvariable vorbelegen
            .onAppear {
                let env = ProcessInfo.processInfo.environment
                if let s = env["HV_SERVER"] { server = s }
                if let u = env["HV_USER"] { username = u }
                if let p = env["HV_PASSWORD"] { password = p }
            }
            #endif
        }
    }

    private func login() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await AppModel.shared.login(server: server, username: username, password: password)
            } catch let e as URLError {
                error = e.code == .timedOut || e.code == .cannotConnectToHost || e.code == .cannotFindHost
                    ? "Server nicht erreichbar. Stimmt die Adresse und bist du im Heimnetz?"
                    : e.localizedDescription
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
