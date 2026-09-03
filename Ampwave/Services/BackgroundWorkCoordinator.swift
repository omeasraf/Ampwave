import Foundation

#if os(iOS)
import BackgroundTasks
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
enum BackgroundWorkCoordinator {

    static var processingTaskIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.ome.Ampwave") + ".processing"
    }

#if os(iOS)
    @available(iOS 26.0, *)
    private static var continuedTaskIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.ome.Ampwave") + ".continued"
    }
#endif

    private static var didRegister = false

#if os(iOS)
    @available(iOS 26.0, *)
    private static var pendingContinuedWork: PendingContinuedWork?

    @available(iOS 26.0, *)
    private static var continuedWorkIsActive = false
#elseif os(macOS)
    private static var deferredMaintenanceTask: Task<Void, Never>?
#endif

    static func activate() {
        guard !didRegister else { return }
        didRegister = true

        installAssertionHook()

#if os(iOS)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: processingTaskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            Task { @MainActor in
                handle(processingTask)
            }
        }

        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: continuedTaskIdentifier,
                using: .main
            ) { task in
                guard let continuedTask = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }

                Task { @MainActor in
                    beginPendingContinuedWork(with: continuedTask)
                }
            }
        }
#endif
    }

    // MARK: - Assertion hook

    private static func installAssertionHook() {
#if os(iOS)
        SongLibrary.beginBackgroundAssertion = { name in
            var identifier: UIBackgroundTaskIdentifier = .invalid

            identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
                if identifier != .invalid {
                    UIApplication.shared.endBackgroundTask(identifier)
                    identifier = .invalid
                }
            }

            return {
                if identifier != .invalid {
                    UIApplication.shared.endBackgroundTask(identifier)
                    identifier = .invalid
                }
            }
        }
#else
        // Native macOS does not have UIApplication background assertions.
        // The app process can continue working when it is not frontmost.
        SongLibrary.beginBackgroundAssertion = { _ in
            return {}
        }
#endif
    }

    // MARK: - Scheduling

    static func scheduleMetadataRefresh() {
        scheduleLibraryMaintenance(requiresNetworkConnectivity: true)
    }

    static func scheduleSonicAnalysis() {
        scheduleLibraryMaintenance(requiresNetworkConnectivity: false)
    }

    private static func scheduleLibraryMaintenance(requiresNetworkConnectivity: Bool) {
#if os(iOS)
        let request = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
        request.requiresNetworkConnectivity = requiresNetworkConnectivity
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            print("[DEBUG] BackgroundWorkCoordinator: Scheduled library maintenance")
        } catch {
            print("[DEBUG] BackgroundWorkCoordinator: Could not schedule: \(error)")
        }
#elseif os(macOS)
        // Native macOS has no BGProcessingTask. Defer inside the running app process.
        deferredMaintenanceTask?.cancel()

        deferredMaintenanceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }

            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.background],
                reason: "Ampwave library maintenance"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
            }

            await runLibraryMaintenance()
            rescheduleUnfinishedWork()
        }

        print("[DEBUG] BackgroundWorkCoordinator: Scheduled macOS library maintenance")
#else
        Task { @MainActor in
            await runLibraryMaintenance()
            rescheduleUnfinishedWork()
        }
#endif
    }

    // MARK: - User-initiated continued processing

    static func performUserInitiated(
        title: String,
        subtitle: String,
        totalUnitCount: Int,
        operation: @escaping @MainActor (UserWorkProgress) async -> Void
    ) async {
        let safeTotal = Int64(max(1, totalUnitCount))

#if os(iOS)
        guard #available(iOS 26.0, *) else {
            let reporter = UserWorkProgress(totalUnitCount: safeTotal)
            await operation(reporter)
            return
        }

        guard pendingContinuedWork == nil, !continuedWorkIsActive else {
            let reporter = UserWorkProgress(totalUnitCount: safeTotal)
            await operation(reporter)
            return
        }

        await withCheckedContinuation { continuation in
            pendingContinuedWork = PendingContinuedWork(
                title: title,
                operation: operation,
                totalUnitCount: safeTotal,
                continuation: continuation
            )

            let request = BGContinuedProcessingTaskRequest(
                identifier: continuedTaskIdentifier,
                title: title,
                subtitle: subtitle
            )
            request.strategy = .fail

            do {
                try BGTaskScheduler.shared.submit(request)

                DiagnosticLog.shared.log(
                    "background",
                    "Submitted continued task title=\(title) total=\(safeTotal)"
                )

                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))

                    guard pendingContinuedWork != nil, !continuedWorkIsActive else {
                        return
                    }

                    BGTaskScheduler.shared.cancel(
                        taskRequestWithIdentifier: continuedTaskIdentifier
                    )

                    DiagnosticLog.shared.log(
                        "background",
                        "Continued task did not start promptly; using foreground fallback"
                    )

                    beginPendingContinuedWork(with: nil)
                }
            } catch {
                DiagnosticLog.shared.log(
                    "background",
                    "Continued task unavailable; using foreground fallback error=\(error.localizedDescription)"
                )

                beginPendingContinuedWork(with: nil)
            }
        }
#elseif os(macOS)
        let reporter = UserWorkProgress(totalUnitCount: safeTotal)

        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: title
        )
        defer {
            ProcessInfo.processInfo.endActivity(activity)
        }

        await operation(reporter)
#else
        let reporter = UserWorkProgress(totalUnitCount: safeTotal)
        await operation(reporter)
#endif
    }

#if os(iOS)
    @available(iOS 26.0, *)
    private static func beginPendingContinuedWork(
        with backgroundTask: BGContinuedProcessingTask?
    ) {
        guard let pending = pendingContinuedWork else {
            backgroundTask?.setTaskCompleted(success: false)
            return
        }

        pendingContinuedWork = nil
        continuedWorkIsActive = true

        let reporter: UserWorkProgress
        if let backgroundTask {
            reporter = UserWorkProgress(
                totalUnitCount: pending.totalUnitCount,
                backgroundTask: backgroundTask
            )
            backgroundTask.updateTitle(pending.title, subtitle: "Starting…")
        } else {
            reporter = UserWorkProgress(totalUnitCount: pending.totalUnitCount)
        }

        let work = Task { @MainActor in
            await pending.operation(reporter)

            let succeeded = !Task.isCancelled

            if succeeded {
                reporter.finish(subtitle: "Completed")
            }

            backgroundTask?.setTaskCompleted(success: succeeded)
            continuedWorkIsActive = false
            pending.continuation.resume()
        }

        backgroundTask?.expirationHandler = {
            DiagnosticLog.shared.log("background", "Continued task expired or was cancelled")
            work.cancel()
        }
    }
#endif

    // MARK: - Handling

#if os(iOS)
    private static func handle(_ task: BGProcessingTask) {
        let work = Task {
            await runLibraryMaintenance()
        }

        task.expirationHandler = {
            work.cancel()
        }

        Task {
            _ = await work.result
            rescheduleUnfinishedWork()
            task.setTaskCompleted(success: !work.isCancelled)
        }
    }
#endif

    private static func runLibraryMaintenance() async {
        await SongLibrary.shared.fetchAutomaticMetadata()

        guard !Task.isCancelled else { return }

        await SonicRecommendationService.shared.waitForPendingAnalysis()
    }

    private static func rescheduleUnfinishedWork() {
        if SonicRecommendationService.shared.hasPendingAnalysis {
            scheduleSonicAnalysis()
        } else if SongLibrary.shared.hasPendingMetadataWork {
            scheduleMetadataRefresh()
        }
    }
}

#if os(iOS)
@available(iOS 26.0, *)
@MainActor
private struct PendingContinuedWork {
    let title: String
    let operation: @MainActor (UserWorkProgress) async -> Void
    let totalUnitCount: Int64
    let continuation: CheckedContinuation<Void, Never>
}
#endif

@MainActor
final class UserWorkProgress {
    private let progress: Progress
    private let updateSystemSubtitle: ((String) -> Void)?

    fileprivate init(totalUnitCount: Int64) {
        self.progress = Progress(totalUnitCount: totalUnitCount)
        self.updateSystemSubtitle = nil
    }

#if os(iOS)
    @available(iOS 26.0, *)
    fileprivate init(
        totalUnitCount: Int64,
        backgroundTask: BGContinuedProcessingTask
    ) {
        let progress = backgroundTask.progress
        progress.totalUnitCount = totalUnitCount
        progress.completedUnitCount = 0

        self.progress = progress

        self.updateSystemSubtitle = { [weak backgroundTask] subtitle in
            backgroundTask?.updateTitle(
                backgroundTask?.title ?? "Ampwave",
                subtitle: subtitle
            )
        }
    }
#endif

    func update(completed: Int, total: Int? = nil, subtitle: String) {
        if let total {
            progress.totalUnitCount = Int64(max(1, total))
        }

        progress.completedUnitCount = min(
            progress.totalUnitCount,
            Int64(max(0, completed))
        )

        updateSystemSubtitle?(subtitle)
    }

    fileprivate func finish(subtitle: String) {
        progress.completedUnitCount = progress.totalUnitCount
        updateSystemSubtitle?(subtitle)
    }
}
