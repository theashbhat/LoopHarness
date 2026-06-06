//
//  RemoteWorkspaceStores.swift
//  Loop
//
//  App-wide registry of the per-backend file + skill stores for remote
//  (OpenClaw VM) execution backends — the Files/Skills analogue of the
//  conversation stores `SimpleConversationManager` keeps. Holding them here
//  (rather than in the sidebar) means their in-memory listing caches survive the
//  drawer opening and closing, and one place keeps every store's config in sync
//  with `ExecutionBackendStore`.
//
//  Pure Foundation so it compiles for the iOS, macOS, and visionOS targets.
//

import Foundation

final class RemoteWorkspaceStores {
    static let shared = RemoteWorkspaceStores()

    private var fileStores: [String: OpenClawFileStore] = [:]
    private var skillStores: [String: OpenClawSkillStore] = [:]

    private init() {
        rebuild()
        NotificationCenter.default.addObserver(
            forName: ExecutionBackendStore.didChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.rebuild()
            }
    }

    /// Create/update/prune the per-backend stores to match the current remote
    /// backend list. Existing stores are reused (and their config refreshed) so
    /// their listing caches aren't thrown away on an unrelated edit.
    private func rebuild() {
        let backends = ExecutionBackendStore.shared.remoteBackends
        for backend in backends {
            if let f = fileStores[backend.id] { f.updateConfig(backend.config) }
            else { fileStores[backend.id] = OpenClawFileStore(backendID: backend.id, config: backend.config) }
            if let s = skillStores[backend.id] { s.updateConfig(backend.config) }
            else { skillStores[backend.id] = OpenClawSkillStore(backendID: backend.id, config: backend.config) }
        }
        let ids = Set(backends.map { $0.id })
        fileStores = fileStores.filter { ids.contains($0.key) }
        skillStores = skillStores.filter { ids.contains($0.key) }
    }

    /// The file store for the active remote backend, or nil when Local is active
    /// (the signal the Files tab uses to fall back to the on-device workspace).
    var activeFileStore: OpenClawFileStore? {
        guard let id = ExecutionBackendStore.shared.activeRemoteBackendID else { return nil }
        return fileStores[id]
    }

    var activeSkillStore: OpenClawSkillStore? {
        guard let id = ExecutionBackendStore.shared.activeRemoteBackendID else { return nil }
        return skillStores[id]
    }

    /// The file store for a specific backend, if one exists. Lets the conversation
    /// store reuse the cached store (and its listing cache) to upload message
    /// attachments into the VM workspace, so an uploaded file also shows up in the
    /// Files tab without a separate fetch.
    func fileStore(for backendID: String) -> OpenClawFileStore? {
        fileStores[backendID]
    }
}
