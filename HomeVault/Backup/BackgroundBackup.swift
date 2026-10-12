import BackgroundTasks
import Photos
import UIKit

/// Hintergrund-Sicherung. iOS entscheidet, wann die Aufgaben laufen:
/// kurz zwischendurch (App-Aktualisierung) und länger nachts beim Laden.
enum BackgroundBackup {
    static let refreshID = "de.justinrossack.homevault.backup.refresh"
    static let processingID = "de.justinrossack.homevault.backup.processing"
    /// Info.plist erlaubt "…continued.*", registriert wird die genaue Kennung
    static let continuedID = "de.justinrossack.homevault.backup.continued.run"

    /// Muss beim Start der App passieren.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { handle($0) }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingID, using: nil) { handle($0) }
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: continuedID, using: nil) { task in
                guard let task = task as? BGContinuedProcessingTask else { return }
                handleContinued(task)
            }
        }
    }

    static func schedule() {
        guard BackupSettings.enabled, !BackupSettings.paused else {
            BGTaskScheduler.shared.cancelAllTaskRequests()
            return
        }
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(refresh)

        let processing = BGProcessingTaskRequest(identifier: processingID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = true
        try? BGTaskScheduler.shared.submit(processing)
    }

    private static func handle(_ task: BGTask) {
        schedule()
        let work = Task { await BackupEngine.shared.run(.background) }
        task.expirationHandler = {
            work.cancel()
            Task { await BackupEngine.shared.cancel() }
        }
        Task {
            await work.value
            task.setTaskCompleted(success: true)
        }
    }

    /// Sicherung von Hand starten. Ab iOS 26 läuft sie mit Fortschrittsanzeige
    /// weiter, auch wenn die App in den Hintergrund geht.
    @MainActor
    static func startManual() {
        if #available(iOS 26.0, *) {
            let req = BGContinuedProcessingTaskRequest(
                identifier: continuedID,
                title: "Fotos sichern",
                subtitle: "Wird vorbereitet …"
            )
            req.strategy = .fail
            if (try? BGTaskScheduler.shared.submit(req)) != nil { return }
        }
        runWithGrace(.manual)
    }

    /// Läuft im Vordergrund und bekommt beim Verlassen der App noch etwas
    /// Nachlaufzeit, statt sofort abzubrechen.
    @MainActor
    static func runWithGrace(_ trigger: BackupEngine.Trigger) {
        final class Token: @unchecked Sendable { var id = UIBackgroundTaskIdentifier.invalid }
        let token = Token()
        token.id = UIApplication.shared.beginBackgroundTask(withName: "backup") {
            Task { await BackupEngine.shared.cancel() }
            UIApplication.shared.endBackgroundTask(token.id)
        }
        Task {
            await BackupEngine.shared.run(trigger)
            UIApplication.shared.endBackgroundTask(token.id)
        }
    }

    @available(iOS 26.0, *)
    private static func handleContinued(_ task: BGContinuedProcessingTask) {
        let progress = task.progress
        progress.totalUnitCount = 1
        let work = Task {
            await BackupEngine.shared.run(.manual) { done, total in
                progress.totalUnitCount = Int64(max(total, 1))
                progress.completedUnitCount = Int64(done)
                task.updateTitle("Fotos sichern", subtitle: "\(done) von \(total)")
            }
        }
        task.expirationHandler = {
            work.cancel()
            Task { await BackupEngine.shared.cancel() }
        }
        Task {
            await work.value
            task.setTaskCompleted(success: true)
        }
    }
}

/// Startet eine Sicherung, sobald neue Fotos dazukommen (App im Vordergrund).
final class PhotoLibraryWatcher: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    static let shared = PhotoLibraryWatcher()
    private var registered = false
    private var pendingWork: DispatchWorkItem?

    func start() {
        guard !registered, BackupEngine.authorized else { return }
        registered = true
        PHPhotoLibrary.shared().register(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        // mehrere Änderungen kurz hintereinander zusammenfassen
        DispatchQueue.main.async { [self] in
            pendingWork?.cancel()
            let work = DispatchWorkItem {
                guard UIApplication.shared.applicationState == .active, BackupSettings.enabled else { return }
                BackgroundBackup.runWithGrace(.foreground)
            }
            pendingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }
}
