import BackgroundTasks
import EidolonCore
import Foundation
import UIKit

/// The opportunistic background run (spec #98): the system decides whether it happens, so
/// nothing here promises a time. It builds its own core, reads the same user library and
/// content bundle as the app, and only notifies when it really made something new.
enum MomentsBackground {
    static let identifier = "com.jacklin.eidolon.moments"

    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: nil
        ) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task {
                _ = await perform()
                task.setTaskCompleted(success: true)
                schedule(after: 15 * 60)
            }
        }
    }

    static func schedule(after seconds: TimeInterval) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date().addingTimeInterval(seconds)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func perform() async -> MomentsRun? {
        let root = URL.applicationSupportDirectory
            .appending(path: "Eidolon", directoryHint: .isDirectory)
        guard let core = try? Eidolon(location: .init(root: root)),
              let settings = try? await core.momentsSettings(),
              settings.enabled
        else { return nil }
        let chatSettings = ChatSettings.load()
        guard let config = chatSettings.config else { return nil }
        let provider = ChatProviderFactory.make(config: config)
        let photo = chatSettings.imageIsConfigured
            ? PhotoTurnContext(
                generator: RemoteImageGenerator(), settings: chatSettings.imageSettings
            )
            : nil
        let gpt = chatSettings.gptImageSettings
        let providers = MomentsProviders(
            chat: provider,
            photo: photo,
            weather: OpenMeteoWeatherClient(),
            gptImage: gpt.enabled ? RemoteGPTImageGenerator() : nil,
            gptSettings: gpt,
            adultMode: chatSettings.adultMode,
            debugMode: UserDefaults.standard.bool(forKey: "debug.mode")
        )
        let run = await core.runMomentsDue(providers: providers)
        if !run.newPosts.isEmpty || !run.newReplies.isEmpty {
            MomentsNotifications.post(posts: run.newPosts.count, replies: run.newReplies.count)
        }
        return run
    }
}
