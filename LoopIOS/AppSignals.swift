//
//  AppSignals.swift
//  Loop
//
//  Lightweight, decoupled app-event signal. Call sites emit neutral named
//  events; an optional receiver may be supplied at runtime to do something
//  with them. When no receiver is present (the common case), emit() is a
//  cheap no-op — nothing is collected, transmitted, or stored.
//

import Foundation

/// Optional sink for app events. A concrete implementation can be provided
/// at runtime; it is discovered by class name via the Objective-C runtime so
/// this file carries no compile-time dependency on it.
@objc protocol AppSignalReceiver: NSObjectProtocol {
    func receive(_ name: String, properties: [String: Any])
}

enum AppSignals {
    /// Resolved once, lazily. `NSClassFromString` returns nil when no receiver
    /// class is compiled into the build, so `receiver` stays nil and every
    /// `emit` is a no-op.
    private static let receiver: AppSignalReceiver? = {
        guard let cls = NSClassFromString("AnalyticsBridge") as? NSObject.Type,
              let instance = cls.init() as? AppSignalReceiver else { return nil }
        return instance
    }()

    /// Emit a named event with optional properties. Safe to call from any
    /// thread; the receiver is responsible for its own threading.
    static func emit(_ name: String, _ properties: [String: Any] = [:]) {
        receiver?.receive(name, properties: properties)
    }
}
