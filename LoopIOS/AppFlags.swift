//
//  AppFlags.swift
//  Loop
//
//  Build-time feature flags sourced from Secrets.xcconfig via Info.plist
//  (`$(LOOP_FLAG)` substitution), mirroring how KeyStore reads bundled API
//  keys. Central, read-only home for flags that change app behavior — add a
//  static here and read `AppFlags.<flag>` anywhere. (LoopIOS/ is compiled into
//  the iOS, Mac, and Vision targets, so these are available on all platforms.)
//

import Foundation

enum AppFlags {

    /// Raw `LOOP_FLAG` value from the build config, or nil when unset. Empty or
    /// an unexpanded `$(LOOP_FLAG)` placeholder (xcconfig key left blank) count
    /// as unset. Most callers want `isManaged`.
    static var loopFlag: String? { string(for: "LOOP_FLAG") }

    /// True when the app is in *managed* mode: the execution backend is fixed
    /// by the build, so backend-switching UI (e.g. the navbar indicator) shows
    /// "Managed" and isn't user-changeable. Set whenever `LOOP_FLAG` is present
    /// in Secrets.xcconfig; absent → the app behaves normally.
    static var isManaged: Bool { loopFlag != nil }

    /// Label shown in place of the backend name when managed.
    static let managedLabel = "Managed"

    // MARK: - Info.plist reader

    /// A non-empty Info.plist string, treating an unexpanded `$(VAR)`
    /// placeholder as missing — same rule KeyStore uses for API keys.
    private static func string(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("$(") { return nil }
        return trimmed
    }
}
