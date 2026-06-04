//
//  AppDelegate.swift
//  Loop
//
//  Created by Ash Bhat on 11/2/24.
//

import UIKit
import UserNotifications

@main
class AppDelegate: UIResponder, UIApplicationDelegate {



    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Take ownership of notification handling so scheduled notifications
        // can be shown while the app is in foreground and so tap routing
        // (rich vs. fallback) lands on the right handler.
        UNUserNotificationCenter.current().delegate = self

        // Wire the iCloud KVS observer before any VC reads onboarding/TTS
        // preferences. Touching KeyStore.shared additionally runs the one-shot
        // migration that moves pre-existing non-sync Keychain entries into
        // the synchronizable namespace so they ride iCloud Keychain.
        iCloudKVSDefaults.shared.bootstrap()
        _ = KeyStore.shared

        // BackgroundScheduler subsumes the old CronSkill. bootstrap() does
        // four things, in order:
        //   1. Migrates any existing `loop.crons` UserDefaults payload to
        //      the new ScheduledJob store.
        //   2. Registers the BGProcessingTask launch handler. This MUST
        //      happen before didFinishLaunchingWithOptions returns or iOS
        //      will refuse to deliver tasks for our identifier.
        //   3. Reconciles every saved job — re-registers placeholder
        //      notifications, GCs exhausted bounded jobs.
        //   4. (No-op on iOS; Mac uses this hook to start its timer loop.)
        BackgroundScheduler.shared.bootstrap()

        // Runner poller — registers the BGAppRefreshTask handler. Must
        // happen before didFinishLaunchingWithOptions returns.
        LoopRunnerPoller.shared.bootstrap()

        // OpenClaw message poller — watches the OpenClaw execution backend(s) for
        // new messages and notifies. Also registers a BGAppRefreshTask handler, so
        // it likewise must run before this method returns.
        OpenClawMessagePoller.shared.bootstrap()

        // APNs registration hooks (inert by default): only registers if the user
        // has already authorized notifications, so no new prompt. The VM-side
        // sender that would push on agent completion is not built yet.
        PushRegistration.shared.registerIfAuthorized()

        return true
    }

    // MARK: - Remote notification registration

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRegistration.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushRegistration.shared.didFailToRegister(error: error)
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Push any pending KVS writes up to iCloud before the app suspends —
        // otherwise a quick "change voice → background" cycle could lose the
        // pulse to the next launch.
        iCloudKVSDefaults.shared.flush()
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }


}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show scheduler banners even while the app is in foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        if BackgroundScheduler.isSchedulerNotification(userInfo),
           let jobId = userInfo["job_id"] as? String {
            // Bookkeeping — bounded jobs decrement, unbounded re-arm.
            BackgroundScheduler.shared.notificationDidFire(jobId: jobId)
        }
        // Runner turn/job notifications — no bookkeeping needed, just display.
        completionHandler([.banner, .sound, .list])
    }

    /// Handle the user tapping a delivered notification. Two paths:
    ///   - prefetched: switch the conversation view to the stored transcript
    ///     so the user lands inside the result with no spinner.
    ///   - fallback:   open a fresh conversation and immediately fire the
    ///     job's prompt as if the user had typed it. Shimmer renders live.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }

        let userInfo = response.notification.request.content.userInfo

        // OpenClaw message notifications — route into the conversation that got
        // the new message. The poller pre-loaded its transcript into the store
        // cache, so this renders immediately.
        if OpenClawMessagePoller.isMessageNotification(userInfo),
           let conversationId = OpenClawMessagePoller.conversationId(from: userInfo) {
            openPrefetchedConversation(id: conversationId)
            return
        }

        // Runner notifications — open the app; the turn id is in userInfo
        // for future deep-linking. For now just foreground the app.
        if LoopRunnerPoller.isRunnerNotification(userInfo) {
            return
        }

        guard BackgroundScheduler.isSchedulerNotification(userInfo) else { return }

        // Bookkeeping first so the next placeholder is queued before we
        // navigate (a slow navigation shouldn't delay the next firing).
        if let jobId = userInfo["job_id"] as? String {
            BackgroundScheduler.shared.notificationDidFire(jobId: jobId)
        }

        let action = BackgroundScheduler.shared.handleTap(userInfo: userInfo)
        switch action {
        case .openConversation(let conversationId):
            openPrefetchedConversation(id: conversationId)
        case .runJobLive(let job, _):
            runJobLiveInForeground(job: job)
        case .unknown:
            break
        }
    }

    // MARK: - Tap routing helpers

    private func openPrefetchedConversation(id: String) {
        guard let messagingVC = Self.findMessagingVC(),
              let conv = SimpleConversationManager.shared.getConversation(by: id) else { return }
        DispatchQueue.main.async {
            messagingVC.loadConversation(conv)
        }
    }

    /// Fallback path — pre-fetch never ran (or fired in a way we can't see).
    /// Create a fresh conversation, set its title from the job, and call
    /// MessagingVC's normal send path with the payload's user prompt. The
    /// shimmer then renders live as the agent loop processes the call.
    /// Only `prompt` payloads have a natural live-run mapping; `skill`
    /// payloads still surface the placeholder (rare in practice — by the
    /// time the user taps, a skill-only job is faster to re-run via the
    /// Settings → Scheduled "Run now" button).
    private func runJobLiveInForeground(job: ScheduledJob) {
        guard let messagingVC = Self.findMessagingVC() else { return }
        switch job.payload {
        case .prompt(let user, _):
            DispatchQueue.main.async {
                let title = "\(job.title) — \(Self.dayLabel(Date()))"
                let conv = SimpleConversationManager.shared.createConversation(title: title)
                messagingVC.loadConversation(conv)
                messagingVC.didSendMessageText(user)
            }
        case .skill:
            // No live-run mapping for raw skill calls; the user can press
            // "Run now" from Settings → Scheduled to retry on demand.
            break
        }
    }

    private static func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    /// Walk the active scene's root view controller tree to find the live
    /// MessagingVC. Mirrors SceneDelegate.findMessagingVC so a notification
    /// tap during cold start still resolves once the storyboard finishes.
    private static func findMessagingVC() -> MessagingVC? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first,
              let root = window.rootViewController else { return nil }
        if let nav = root as? UINavigationController {
            for vc in nav.viewControllers {
                if let mvc = vc as? MessagingVC { return mvc }
            }
        }
        if let mvc = root as? MessagingVC { return mvc }
        return nil
    }
}
