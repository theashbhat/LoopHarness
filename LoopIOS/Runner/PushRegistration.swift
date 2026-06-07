//
//  PushRegistration.swift
//  Loop
//
//  APNs device-token registration hooks. This is the client half of the
//  push-on-completion path: it obtains an APNs device token, persists it, and
//  registers it with the loopharness push backend so a VM-side sender (e.g. a
//  cron finishing on the VM) can alert the user when a long-running agent turn
//  finishes while the app is backgrounded.
//
//  Registration is inert by default: we only call `registerForRemoteNotifications()`
//  when the user has ALREADY granted notification authorization (the
//  scheduler/runner local-notification flows request it), so this adds no new
//  permission prompt. Backend transmission goes through `PushBridge`, whose
//  concrete sender lives in the gitignored `LoopIOS/Private/` folder — so public
//  clones (no sender compiled in) retain the token locally and post nothing.
//
//  Wiring points (AppDelegate):
//    - didFinishLaunchingWithOptions -> registerIfAuthorized()
//    - didRegisterForRemoteNotificationsWithDeviceToken -> store + registerWithBackend
//    - didFailToRegisterForRemoteNotificationsWithError  -> log
//
//  Call `registerIfAuthorized()` again right after a notification-permission
//  grant to obtain the token immediately rather than on the next launch.
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

    /// Stores the token and hands it to the backend. Called from
    /// `didRegisterForRemoteNotificationsWithDeviceToken`.
    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: Self.tokenKey)
        Self.log.info("APNs device token registered (\(hex.count, privacy: .public) hex chars)")
        registerWithBackend(token: hex)
    }

    func didFailToRegister(error: Error) {
        Self.log.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Backend registration

    /// Hands the device token to `PushBridge`, which (when its private sender is
    /// present) upserts it on the loopharness push backend at
    /// `POST /loopharness/push/register`. Also emits an app signal for analytics.
    private func registerWithBackend(token: String) {
        let environment = Self.apnsEnvironment()
        PushBridge.register(token: token, environment: environment)
        AppSignals.emit("push_token_registered", ["environment": environment])
        Self.log.info("push token handed to bridge (env: \(environment, privacy: .public))")
    }

    // MARK: - APNs environment

    /// The backend `environment` string for this build's APNs token:
    /// "sandbox" for development APNs, "production" for production APNs. The
    /// backend uses it to pick the matching APNs host when sending.
    ///
    /// Resolved from the embedded provisioning profile's `aps-environment`
    /// entitlement when available (development -> sandbox, production ->
    /// production). App Store builds carry no embedded profile, so they fall
    /// back to the compile-time configuration (Release -> production). Xcode
    /// dev builds resolve to sandbox; TestFlight/App Store to production.
    static func apnsEnvironment() -> String {
        if let aps = apsEnvironmentFromProvisioning() {
            return aps == "production" ? "production" : "sandbox"
        }
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    /// Parse `aps-environment` out of the embedded mobileprovision, if present.
    private static func apsEnvironmentFromProvisioning() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .ascii),
              let start = raw.range(of: "<plist"),
              let end = raw.range(of: "</plist>") else {
            return nil
        }
        let plistString = String(raw[start.lowerBound..<end.upperBound])
        guard let plistData = plistString.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let aps = entitlements["aps-environment"] as? String else {
            return nil
        }
        return aps
    }
}
