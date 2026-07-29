import BackgroundTasks
import SwiftUI

@main
struct MonicaSyncApp: App {
    static let refreshTaskIdentifier = "com.monicahq.MonicaSync.refresh"

    @State private var model: AppModel
    @State private var syncCoordinator: SyncCoordinator
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel()
        let coordinator = SyncCoordinator()
        _model = State(initialValue: model)
        _syncCoordinator = State(initialValue: coordinator)

        // Must be registered before the app finishes launching.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handleRefresh(task: refreshTask, model: model, coordinator: coordinator)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if model.isConfigured {
                    RootView()
                } else {
                    OnboardingView()
                }
            }
            .environment(model)
            .environment(syncCoordinator)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Self.scheduleRefresh()
            }
        }
    }

    // MARK: - Background refresh

    private nonisolated static func handleRefresh(
        task: BGAppRefreshTask,
        model: AppModel,
        coordinator: SyncCoordinator
    ) {
        scheduleRefresh()
        let work = Task { @MainActor in
            await coordinator.sync(model: model)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    nonisolated static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
