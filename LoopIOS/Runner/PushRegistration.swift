//
//  PushRegistration.swift
//  Loop
//
//  APNs device-token registration hooks. This is the client half of the planned
//  push-on-completion path: it obtains an APNs device token and persists it, so a
//  future VM-side sender can wake the app (silent `content-available`) or alert
//  the user when a long-running agent turn finishes while the app is backgrounded.
//
//  The VM-side sender is intentionally NOT built yet — `transmitToVM(token:)` is a
//  documented stub. Registration is also inert by default: we only call
//  `registerForRemoteNotifications()` when the user has ALREADY granted
//  notification authorization (the scheduler/runner local-notification flows
//  request it), so this adds no new permission prompt and changes no behavior.
//
//  Wiring points (AppDelegate):
//    - didFinishLaunchingWithOptions -> registerIfAuthorized()
//    - didRegisterForRemoteNotificationsWithDeviceToken -> store + transmitToVM
//    - didFailToRegisterForRemoteNotificationsWithError  -> log
//

import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#endif
import os

final class PushRegistration {

    static let shared = PushRegistration()

    private static let log = Logger(subsystem: "com.bhat.intel", category: "PushRegistration")

    /// UserDefaults key for the most recent hex-encoded APNs device token.
    private static let tokenKey = "loop.apns.deviceToken"

    private init() {}

    /// The last device token we received, if any.
    var deviceToken: String? {
        UserDefaults.standard.string(forKey: Self.tokenKey)
    }

    /// Registers for remote notifications **only** if the user has already
    /// authorized notifications, so no new permission prompt appears. Call from
    /// `didFinishLaunchingWithOptions`.
    func registerIfAuthorized() {
        #if os(iOS)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                Self.log.info("notifications not authorized — skipping APNs registration")
                return
            }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        #endif
    }

    /// Stores the token and (eventually) hands it to the VM. Called from
    /// `didRegisterForRemoteNotificationsWithDeviceToken`.
    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: Self.tokenKey)
        Self.log.info("APNs device token registered (\(hex.count, privacy: .public) hex chars)")
        transmitToVM(token: hex)
    }

    func didFailToRegister(error: Error) {
        Self.log.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Stub: transmit to VM (sender deferred)

    /// Intended contract (NOT yet implemented): POST the device token to the VM
    /// over the persistent tunnel (e.g. `POST /device-token` on the Go runner)
    /// so a VM-side sender holding the APNs `.p8` key can push on turn/job
    /// completion. For now this only logs — there is no VM endpoint or sender.
    private func transmitToVM(token: String) {
        Self.log.info("transmitToVM: deferred — no VM sender yet (token retained locally)")
    }
}
