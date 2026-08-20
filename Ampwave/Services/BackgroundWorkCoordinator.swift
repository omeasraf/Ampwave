//
//  BackgroundWorkCoordinator.swift
//  Ampwave
//
//  Keeps long-running library work (metadata fetching) alive when the user
//  leaves the app, and reschedules whatever didn't finish.
//
//  Two mechanisms, because neither alone is enough:
//   • A UIApplication background-task assertion holds execution open for the
//     grace period right after backgrounding, so an in-flight batch isn't
//     suspended mid-song.
//   • A BGProcessingTask picks the work back up later once the OS decides
//     it's a good time, which is what covers large libraries.
//

import BackgroundTasks
import Foundation
import UIKit

@MainActor
enum BackgroundWorkCoordinator {

  /// Must match an entry in Info.plist's BGTaskSchedulerPermittedIdentifiers.
  static var processingTaskIdentifier: String {
    (Bundle.main.bundleIdentifier ?? "com.ome.Ampwave") + ".processing"
  }

  private static var didRegister = false

  /// Call once at launch, before the app finishes launching.
  static func activate() {
    guard !didRegister else { return }
    didRegister = true

    installAssertionHook()

    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: processingTaskIdentifier,
      using: nil
    ) { task in
      // `using: nil` runs this on a background queue, so hop to the main
      // actor rather than asserting isolation — the library and its status
      // are main-actor isolated.
      guard let processingTask = task as? BGProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }
      Task { @MainActor in
        handle(processingTask)
      }
    }
  }

  // MARK: - Assertion hook

  /// Lets `SongLibrary` (which also compiles into the watch app and the
  /// Lyrics extension, where `UIApplication.shared` is unavailable) hold a
  /// background assertion without importing UIKit itself.
  private static func installAssertionHook() {
    SongLibrary.beginBackgroundAssertion = { name in
      var identifier: UIBackgroundTaskIdentifier = .invalid

      // The expiration handler must end the task or the OS terminates the app.
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
  }

  // MARK: - Scheduling

  /// Asks the system to run another metadata pass later. Safe to call often;
  /// submitting replaces any pending request for the same identifier.
  static func scheduleMetadataRefresh() {
    let request = BGProcessingTaskRequest(identifier: processingTaskIdentifier)
    request.requiresNetworkConnectivity = true
    request.requiresExternalPower = false
    // A short floor rather than none, so backgrounding doesn't immediately
    // race the assertion that's still finishing the current batch.
    request.earliestBeginDate = Date(timeIntervalSinceNow: 60)

    do {
      try BGTaskScheduler.shared.submit(request)
      print("[DEBUG] BackgroundWorkCoordinator: Scheduled metadata refresh")
    } catch {
      // Simulator never permits BG task submission, and the OS refuses when
      // the app is in an ineligible state — neither is worth surfacing.
      print("[DEBUG] BackgroundWorkCoordinator: Could not schedule: \(error)")
    }
  }

  // MARK: - Handling

  private static func handle(_ task: BGProcessingTask) {
    let work = Task {
      await SongLibrary.shared.fetchAutomaticMetadata()
    }

    task.expirationHandler = {
      work.cancel()
    }

    Task {
      _ = await work.result
      // Anything still unfetched gets another window later.
      if SongLibrary.shared.hasPendingMetadataWork {
        scheduleMetadataRefresh()
      }
      task.setTaskCompleted(success: !work.isCancelled)
    }
  }
}
