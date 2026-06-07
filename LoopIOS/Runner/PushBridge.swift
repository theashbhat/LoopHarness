//
//  PushBridge.swift
//  Loop
//
//  Decoupled seam for registering this device's APNs token with the backend.
//  Mirrors `AppSignals`: the public code carries no compile-time dependency on
//  the concrete sender. A receiver is discovered at runtime by class name via
//  the Objective-C runtime, so when the private implementation is absent (public
//  clones), `register(...)` is a cheap no-op — nothing is transmitted or stored.
//
//  The concrete receiver lives in the gitignored `LoopIOS/Private/` folder
//  (`PushTokenBridge`), alongside `AnalyticsBridge`, and POSTs the token to the
//  loopharness push backend. See `LoopIOS/Private/PUSH_NOTIFICATIONS.md`.
//

import Foundation

/// Optional sink for the APNs device token. A concrete implementation can be
/// provided at runtime; it is discovered by class name via the Objective-C
/// runtime so this file carries no compile-time dependency on it.
@objc protocol PushTokenReceiver: NSObjectProtocol {
    /// Hand the hex-encoded APNs device token to the backend. `environment` is
    /// the APNs environment this token belongs to ("sandbox" or "production"),
    /// so the backend routes pushes to the matching APNs host.
    func registerToken(_ token: String, environment: String)
}

enum PushBridge {
    /// Resolved once, lazily. `NSClassFromString` returns nil when no receiver
    /// class is compiled into the build, so `receiver` stays nil and every
    /// `register` is a no-op.
    private static let receiver: PushTokenReceiver? = {
        guard let cls = NSClassFromString("PushTokenBridge") as? NSObject.Type,
              let instance = cls.init() as? PushTokenReceiver else { return nil }
        return instance
    }()

    /// Register the device token with the backend. Safe to call from any thread;
    /// the receiver is responsible for its own threading.
    static func register(token: String, environment: String) {
        receiver?.registerToken(token, environment: environment)
    }
}
