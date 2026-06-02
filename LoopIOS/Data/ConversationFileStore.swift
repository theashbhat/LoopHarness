//
//  ConversationFileStore.swift
//  Loop
//
//  Conversation persistence backed by iCloud Documents. One append-only
//  NDJSON file per conversation under:
//
//      iCloud.com.bhat.LoopIOS/Documents/messages/<conversation-uuid>.ndjson
//
//  File format — one JSON object per line:
//      {"_type":"meta","id":"…","title":"…","createdAt":"…","updatedAt":"…"}
//      {"_type":"msg","id":"…","role":"user","content":"…","createdAt":"…"}
//      {"_type":"msg","id":"…","role":"assistant","content":"…","createdAt":"…"}
//      {"_type":"meta","id":"…","title":"…","createdAt":"…","updatedAt":"…"}
//
//  Reads use the LAST meta line (so a title rename or updatedAt bump wins) and
//  collect all msg lines in createdAt order. Writes append a single line and
//  bump the meta as needed.
//
//  Threading model:
//    Reads (`allConversations`, `mostRecentlyUpdatedConversation`,
//    `conversation(id:)`, `messages(forConversation:)`) are answered from an
//    in-memory cache under a short `cacheLock`. They NEVER touch disk or
//    enter `ioQueue`. The cache is populated by a two-pass init:
//
//      Pass 1 (sync, in `init`): enumerate `*.ndjson` filenames and read just
//      the trailing meta line of each (backward 4 KB FileHandle peek).
//      iCloud-evicted files fall back to filesystem `contentModificationDate`
//      for sort order. Cheap; bounded; safe on main.
//
//      Pass 2 (async, dispatched at end of `init` onto `ioQueue`): parse each
//      file's full message body. Includes `ensureDownloadedLocked` for evicted
//      files — which is the part that USED to stall the main thread for up to
//      5 s. Now strictly off-thread.
//
//    Writes update the cache synchronously (UI sees the change instantly) and
//    dispatch the actual file append/rewrite onto `ioQueue`. A `pendingWrites`
//    set guards against an in-flight metadata-driven refresh dropping a
//    locally-created row that hasn't hit disk yet.
//
//  Cross-device sync:
//    NSMetadataQuery watches the messages/ folder. On update we do a
//    surgical diff (compare on-disk file `updatedAt` against cached) on
//    `ioQueue`, only re-parsing entries that actually changed. `isSyncing`
//    flips true for the duration; UI observes
//    `.conversationStoreSyncStateChanged` to drive the sidebar spinner.
//

import Foundation

final class ConversationFileStore: ConversationStore {

    static let shared = ConversationFileStore()

    /// This store owns the local / iCloud backend. Conversations it creates are
    /// stamped `"local"`.
    let backendMarker = ConversationBackend.local.rawValue

    /// iCloud container declared in the entitlements + Info.plist's
    /// `NSUbiquitousContainers`.
    private static let containerIdentifier = "iCloud.com.bhat.intel"

    /// Subfolder under the ubiquity container's Documents directory. User-
    /// visible name in the Files app is "messages".
    private static let folderName = "messages"

    enum Backend { case iCloud, local }
    let backend: Backend
    let rootURL: URL

    // MARK: - State (all access ordered through `cacheLock`)

    private let cacheLock = NSLock()
    /// Conversations keyed by id. Authoritative source for all reads.
    private var cache: [String: SimpleConversation] = [:]
    /// Conversation ids in updatedAt-desc order, kept in sync with `cache`.
    /// Avoids re-sorting on every `allConversations()` call.
    private var orderedIds: [String] = []
    /// Ids whose `messages` array has been fully parsed from disk. Cache
    /// entries not in this set carry meta-only data (empty `messages`).
    private var hydratedIds: Set<String> = []
    /// Ids whose disk write is dispatched to `ioQueue` but hasn't completed
    /// yet. Refreshes triggered by NSMetadataQuery skip "this id isn't on
    /// disk anymore" pruning for ids in this set so we don't drop newly-
    /// created local rows.
    private var pendingWrites: Set<String> = []
    /// Ids currently being hydrated on `ioQueue`. Prevents stacking up
    /// duplicate hydration tasks.
    private var inflightHydrations: Set<String> = []
    /// True while the metadata-query-triggered refresh is running.
    private var inflightRefresh: Bool = false

    /// Background queue for ALL disk I/O. Reads never enter here.
    private let ioQueue = DispatchQueue(label: "loop.conversationFileStore.io",
                                        qos: .utility)

    /// NSMetadataQuery that watches messages/ for remote iCloud changes.
    /// Nil on the `.local` backend.
    private var metadataQuery: NSMetadataQuery?

    /// Coalesces back-to-back `.conversationStoreDidChange` posts (e.g. when
    /// pass 2 hydration finishes 50 files in a burst). The work item posts
    /// once and resets.
    private var changePostWorkItem: DispatchWorkItem?

    // MARK: - Init

    private init() {
        let fm = FileManager.default

        if let ubiquity = fm.url(forUbiquityContainerIdentifier: Self.containerIdentifier) {
            let docs = ubiquity.appendingPathComponent("Documents", isDirectory: true)
            let messages = docs.appendingPathComponent(Self.folderName, isDirectory: true)
            try? fm.createDirectory(at: messages, withIntermediateDirectories: true)
            self.backend = .iCloud
            self.rootURL = messages
            print("📦 ConversationFileStore: iCloud at \(messages.path)")
        } else {
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let local = appSupport.appendingPathComponent("Loop").appendingPathComponent(Self.folderName, isDirectory: true)
            try? fm.createDirectory(at: local, withIntermediateDirectories: true)
            self.backend = .local
            self.rootURL = local
            print("⚠️ ConversationFileStore: iCloud unavailable — local fallback at \(local.path)")
        }

        // Pass 1 (synchronous, cheap): meta-only enumeration so reads have
        // something to answer with immediately.
        bootstrapMetaCacheSync()

        // Pass 2 (async): full hydration of every conversation's messages.
        // Files that need an iCloud download wait do it here, never on main.
        if backend == .iCloud {
            scheduleFullHydration()
        } else {
            // Local: pass 1 was cheap and already full-content for small files;
            // but to keep semantics identical we still hydrate async so the
            // pre/post-hydration code paths behave the same.
            scheduleFullHydration()
        }

        startMetadataQueryIfNeeded()
    }

    // MARK: - Public read API
    //
    // All return from cache. Reads do NOT block on disk or iCloud download.
    // If a caller asks for messages of a conversation that hasn't been
    // hydrated yet, the cached entry's `messages` may be empty — we kick off
    // an async hydration and the caller is expected to refresh from store
    // when `.conversationStoreDidChange` fires.

    func allConversations() -> [SimpleConversation] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return orderedIds.compactMap { cache[$0] }
    }

    func conversation(id: String) -> SimpleConversation? {
        cacheLock.lock()
        let conv = cache[id]
        let hydrated = hydratedIds.contains(id)
        cacheLock.unlock()
        if conv != nil && !hydrated { hydrateAsync(id: id) }
        return conv
    }

    /// The conversation with the newest meta.updatedAt — what both iPhone and
    /// Mac load on launch. Returns nil if the cache is empty (folder is empty
    /// or pass 1 found nothing).
    func mostRecentlyUpdatedConversation() -> SimpleConversation? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let first = orderedIds.first else { return nil }
        return cache[first]
    }

    func messages(forConversation id: String) -> [SimpleMessage] {
        cacheLock.lock()
        let msgs = cache[id]?.messages ?? []
        let hydrated = hydratedIds.contains(id)
        let exists = cache[id] != nil
        cacheLock.unlock()
        if exists && !hydrated { hydrateAsync(id: id) }
        return msgs
    }

    /// True while pass-2 hydration or a metadata-driven refresh is active.
    /// Always false on the local backend (no remote sync to wait for).
    var isSyncing: Bool {
        guard backend == .iCloud else { return false }
        cacheLock.lock(); defer { cacheLock.unlock() }
        return inflightRefresh || !inflightHydrations.isEmpty
    }

    // MARK: - Public write API
    //
    // Cache mutates synchronously so the UI reflects user actions instantly.
    // The disk write is dispatched async. Notification posts run on main.

    func createConversation(title: String) -> SimpleConversation {
        let conv = SimpleConversation(title: title, backend: backendMarker)
        cacheLock.lock()
        cache[conv.id] = conv
        hydratedIds.insert(conv.id) // new, no disk content to wait for
        pendingWrites.insert(conv.id)
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
        postChangeNotification()
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            self.appendLine(MetaLine(_type: "meta",
                                     id: conv.id,
                                     title: conv.title,
                                     createdAt: conv.createdAt,
                                     updatedAt: conv.updatedAt,
                                     backend: conv.backend),
                            to: self.fileURL(for: conv.id))
            self.cacheLock.lock()
            self.pendingWrites.remove(conv.id)
            self.cacheLock.unlock()
        }
        return conv
    }

    func saveConversation(_ conversation: SimpleConversation) {
        var updated = conversation
        updated.updatedAt = Date()
        cacheLock.lock()
        cache[updated.id] = updated
        pendingWrites.insert(updated.id)
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
        postChangeNotification()
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            self.appendLine(MetaLine(_type: "meta",
                                     id: updated.id,
                                     title: updated.title,
                                     createdAt: updated.createdAt,
                                     updatedAt: updated.updatedAt,
                                     backend: updated.backend),
                            to: self.fileURL(for: updated.id))
            self.cacheLock.lock()
            self.pendingWrites.remove(updated.id)
            self.cacheLock.unlock()
        }
    }

    func deleteConversation(id: String) {
        cacheLock.lock()
        cache.removeValue(forKey: id)
        hydratedIds.remove(id)
        pendingWrites.remove(id)
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
        postChangeNotification()
        let url = fileURL(for: id)
        ioQueue.async { [weak self] in
            self?.coordinatedRemove(url)
        }
    }

    func addMessage(_ message: SimpleMessage, toConversation id: String) {
        cacheLock.lock()
        var conv = cache[id] ?? SimpleConversation(id: id, title: "Untitled")
        conv.messages.append(message)
        conv.updatedAt = Date()
        cache[id] = conv
        hydratedIds.insert(id) // we know the latest message at minimum
        pendingWrites.insert(id)
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
        let convSnapshot = conv
        postChangeNotification()
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let url = self.fileURL(for: id)
            self.appendLine(MessageLineEnvelope(message: message), to: url)
            // Bump meta so directory listings + late readers see the new
            // updatedAt without parsing every msg line.
            self.appendLine(MetaLine(_type: "meta",
                                     id: convSnapshot.id,
                                     title: convSnapshot.title,
                                     createdAt: convSnapshot.createdAt,
                                     updatedAt: convSnapshot.updatedAt,
                                     backend: convSnapshot.backend),
                            to: url)
            self.cacheLock.lock()
            self.pendingWrites.remove(id)
            self.cacheLock.unlock()
        }
    }

    /// Rewrites the whole file without the given message. Rare op (Mac
    /// escape-cancel).
    func removeMessage(id messageId: String, fromConversation conversationId: String) {
        cacheLock.lock()
        guard var conv = cache[conversationId] else { cacheLock.unlock(); return }
        conv.messages.removeAll(where: { $0.id == messageId })
        conv.updatedAt = Date()
        cache[conversationId] = conv
        pendingWrites.insert(conversationId)
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
        let snapshot = conv
        postChangeNotification()
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            self.rewriteFile(for: snapshot)
            self.cacheLock.lock()
            self.pendingWrites.remove(conversationId)
            self.cacheLock.unlock()
        }
    }

    // MARK: - Pass 1: cheap synchronous bootstrap
    //
    // Reads only the trailing meta line of each .ndjson file. For evicted
    // iCloud files we skip the disk read and fall back to a placeholder
    // entry (title = filename) whose updatedAt comes from contentModificationDate
    // — close enough for sort order; pass 2 will replace it with real data.

    private func bootstrapMetaCacheSync() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey,
                                         .ubiquitousItemDownloadingStatusKey,
                                         .isUbiquitousItemKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var seeds: [SimpleConversation] = []
        for url in entries where url.pathExtension == "ndjson" {
            let id = url.deletingPathExtension().lastPathComponent
            if let conv = readTrailingMeta(at: url, fallbackId: id) {
                seeds.append(conv)
            }
        }

        cacheLock.lock()
        for conv in seeds {
            cache[conv.id] = conv
            // Not hydrated yet — `messages` is still empty.
        }
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
    }

    /// Read the last meta line by tail-scanning the file. Bounded read; if
    /// the file is iCloud-evicted, return a placeholder using fs mtime.
    private func readTrailingMeta(at url: URL, fallbackId: String) -> SimpleConversation? {
        let values = try? url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .ubiquitousItemDownloadingStatusKey,
            .isUbiquitousItemKey,
        ])
        let isUbiquitous = values?.isUbiquitousItem ?? false
        let isCurrent = values?.ubiquitousItemDownloadingStatus == .current
        let mtime = values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)

        if isUbiquitous && !isCurrent {
            // Don't pay the download wait on the main thread. Stub the entry
            // using fs mtime; pass 2 will hydrate properly.
            return SimpleConversation(
                id: fallbackId,
                title: "Conversation",
                messages: [],
                createdAt: mtime,
                updatedAt: mtime
            )
        }

        // Read just the trailing 4 KB and look for the LAST {"_type":"meta" line.
        let tailBytes = 4096
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize: UInt64
        do { fileSize = try handle.seekToEnd() } catch { return nil }
        if fileSize == 0 { return nil }
        let readFrom = fileSize > UInt64(tailBytes) ? fileSize - UInt64(tailBytes) : 0
        do { try handle.seek(toOffset: readFrom) } catch { return nil }
        guard let tail = try? handle.readToEnd(),
              let text = String(data: tail, encoding: .utf8) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var lastMeta: MetaLine?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"_type\":\"meta\""),
                  let data = line.data(using: .utf8),
                  let meta = try? decoder.decode(MetaLine.self, from: data) else { continue }
            lastMeta = meta
        }
        guard let meta = lastMeta else {
            // No meta in tail (unusual — maybe a tiny file, full read fallback).
            return SimpleConversation(id: fallbackId, title: "Conversation",
                                      messages: [], createdAt: mtime, updatedAt: mtime)
        }
        return SimpleConversation(
            id: meta.id,
            title: meta.title,
            messages: [],
            createdAt: meta.createdAt,
            updatedAt: meta.updatedAt,
            backend: meta.backend
        )
    }

    // MARK: - Pass 2: async full hydration
    //
    // For each known id, parse the full file (waiting on iCloud download if
    // needed) and replace the cache entry's messages. Posts a coalesced
    // change notification when the batch settles.

    private func scheduleFullHydration() {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            // Snapshot ids to hydrate from current cache.
            self.cacheLock.lock()
            let ids = self.orderedIds
            for id in ids where !self.hydratedIds.contains(id) {
                self.inflightHydrations.insert(id)
            }
            self.cacheLock.unlock()
            self.postSyncStateNotification()

            for id in ids {
                self.hydrateNow(id: id)
            }

            // All done — drop the inflight flags. Notification posts already
            // happened per-batch via the debounce.
            self.cacheLock.lock()
            self.inflightHydrations.removeAll()
            self.cacheLock.unlock()
            self.postSyncStateNotification()
        }
    }

    /// Single-id async hydration triggered by an external read of an
    /// unhydrated row (e.g. user clicks an unread conversation).
    private func hydrateAsync(id: String) {
        cacheLock.lock()
        let alreadyInflight = inflightHydrations.contains(id)
        let alreadyHydrated = hydratedIds.contains(id)
        if !alreadyInflight && !alreadyHydrated {
            inflightHydrations.insert(id)
        }
        cacheLock.unlock()
        if alreadyInflight || alreadyHydrated { return }
        postSyncStateNotification()
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            self.hydrateNow(id: id)
            self.cacheLock.lock()
            self.inflightHydrations.remove(id)
            self.cacheLock.unlock()
            self.postSyncStateNotification()
        }
    }

    /// Must be called on `ioQueue`. Reads the full file (with iCloud
    /// download wait if evicted), parses messages, and merges into cache.
    private func hydrateNow(id: String) {
        let url = fileURL(for: id)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            // Disappeared since pass 1. Drop from cache unless there's a
            // pending local write for it.
            cacheLock.lock()
            if !pendingWrites.contains(id) {
                cache.removeValue(forKey: id)
                hydratedIds.remove(id)
                recomputeOrderedIdsLocked()
            }
            cacheLock.unlock()
            postChangeNotification()
            return
        }

        if backend == .iCloud {
            ensureDownloaded(url, timeout: 5)
        }

        guard let parsed = parseFullFile(at: url, fallbackId: id) else { return }

        cacheLock.lock()
        // If the local row has unflushed writes, keep them and just update
        // hydration status — don't stomp the user's recent activity.
        if !pendingWrites.contains(id) {
            cache[id] = parsed
        }
        hydratedIds.insert(id)
        recomputeOrderedIdsLocked()
        cacheLock.unlock()
        postChangeNotification()
    }

    /// Full-file parse. Called on `ioQueue`.
    private func parseFullFile(at url: URL, fallbackId: String) -> SimpleConversation? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var title = "Untitled"
        var createdAt = Date()
        var updatedAt = Date()
        var backend: String? = nil
        var foundMeta = false
        var messages: [SimpleMessage] = []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8) else { continue }
            if let envelope = try? decoder.decode(LineEnvelope.self, from: lineData) {
                switch envelope._type {
                case "meta":
                    if let meta = try? decoder.decode(MetaLine.self, from: lineData) {
                        title = meta.title
                        createdAt = meta.createdAt
                        updatedAt = meta.updatedAt
                        backend = meta.backend
                        foundMeta = true
                    }
                case "msg":
                    if let msg = try? decoder.decode(SimpleMessage.self, from: lineData) {
                        messages.append(msg)
                    }
                default:
                    continue
                }
            }
        }

        guard foundMeta else { return nil }
        messages.sort { $0.createdAt < $1.createdAt }
        return SimpleConversation(
            id: fallbackId, title: title, messages: messages,
            createdAt: createdAt, updatedAt: updatedAt, backend: backend
        )
    }

    // MARK: - NSMetadataQuery (cross-device sync)

    private func startMetadataQueryIfNeeded() {
        guard backend == .iCloud else { return }
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(format: "%K LIKE '*.ndjson'", NSMetadataItemFSNameKey)
        NotificationCenter.default.addObserver(
            self, selector: #selector(metadataDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate, object: q
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(metadataDidUpdate(_:)),
            name: .NSMetadataQueryDidFinishGathering, object: q
        )
        DispatchQueue.main.async { q.start() }
        self.metadataQuery = q
    }

    @objc private func metadataDidUpdate(_ note: Notification) {
        cacheLock.lock()
        if inflightRefresh { cacheLock.unlock(); return }
        inflightRefresh = true
        cacheLock.unlock()
        postSyncStateNotification()
        ioQueue.async { [weak self] in
            self?.surgicalRefresh()
            self?.cacheLock.lock()
            self?.inflightRefresh = false
            self?.cacheLock.unlock()
            self?.postSyncStateNotification()
        }
    }

    /// Walks the messages/ folder and reconciles every file with the cache.
    /// Files newer than the cached `updatedAt` get re-parsed; files that
    /// disappeared get evicted from the cache UNLESS we have a pending local
    /// write for them (the disk write just hasn't landed yet).
    private func surgicalRefresh() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        var onDiskIds: Set<String> = []
        var anyChange = false
        for url in entries where url.pathExtension == "ndjson" {
            let id = url.deletingPathExtension().lastPathComponent
            onDiskIds.insert(id)

            // What does the file claim its updatedAt is? Peek the trailing
            // meta line. If newer than our cache, re-hydrate the row.
            guard let stub = readTrailingMeta(at: url, fallbackId: id) else { continue }
            cacheLock.lock()
            let cachedUpdated = cache[id]?.updatedAt ?? Date(timeIntervalSince1970: 0)
            let needsRefresh = stub.updatedAt > cachedUpdated
            cacheLock.unlock()
            if needsRefresh {
                if backend == .iCloud { ensureDownloaded(url, timeout: 5) }
                if let parsed = parseFullFile(at: url, fallbackId: id) {
                    cacheLock.lock()
                    if !pendingWrites.contains(id) {
                        cache[id] = parsed
                    }
                    hydratedIds.insert(id)
                    recomputeOrderedIdsLocked()
                    cacheLock.unlock()
                    anyChange = true
                }
            }
        }

        // Evict cache entries whose files disappeared, except those with
        // pending writes (the disk write probably hasn't landed yet).
        cacheLock.lock()
        let cachedIds = Set(cache.keys)
        let evictable = cachedIds.subtracting(onDiskIds).subtracting(pendingWrites)
        for id in evictable {
            cache.removeValue(forKey: id)
            hydratedIds.remove(id)
            anyChange = true
        }
        if anyChange { recomputeOrderedIdsLocked() }
        cacheLock.unlock()

        if anyChange { postChangeNotification() }
    }

    // MARK: - Notifications (debounced)

    /// Post `.conversationStoreDidChange` on main, coalescing burst calls
    /// into a single delivery ~100 ms later. Used when pass 2 hydrates many
    /// files in quick succession.
    private func postChangeNotification() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.changePostWorkItem?.cancel()
            let item = DispatchWorkItem {
                NotificationCenter.default.post(name: .conversationStoreDidChange,
                                                object: nil)
            }
            self.changePostWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
        }
    }

    private func postSyncStateNotification() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .conversationStoreSyncStateChanged,
                                            object: nil)
        }
    }

    // MARK: - Ordered-ids helper (must hold `cacheLock`)

    private func recomputeOrderedIdsLocked() {
        orderedIds = cache.keys.sorted { lhs, rhs in
            (cache[lhs]?.updatedAt ?? .distantPast) > (cache[rhs]?.updatedAt ?? .distantPast)
        }
    }

    // MARK: - Disk I/O (callable from `ioQueue`)

    private func fileURL(for conversationId: String) -> URL {
        return rootURL.appendingPathComponent("\(conversationId).ndjson")
    }

    private func appendLine<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        var line = data
        line.append(0x0A)
        coordinatedAppend(to: url, append: line)
    }

    private func rewriteFile(for conversation: SimpleConversation) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var body = Data()
        if let metaData = try? encoder.encode(MetaLine(
            _type: "meta", id: conversation.id,
            title: conversation.title,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            backend: conversation.backend
        )) {
            body.append(metaData); body.append(0x0A)
        }
        for msg in conversation.messages {
            if let d = try? encoder.encode(MessageLineEnvelope(message: msg)) {
                body.append(d); body.append(0x0A)
            }
        }
        coordinatedWrite(to: fileURL(for: conversation.id), data: body)
    }

    private func coordinatedWrite(to url: URL, data: Data) {
        if backend != .iCloud {
            try? data.write(to: url, options: [.atomic])
            return
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { writeURL in
            try? data.write(to: writeURL, options: [.atomic])
        }
        if let err = coordError {
            print("⚠️ ConversationFileStore: coordinated write failed: \(err.localizedDescription)")
        }
    }

    private func coordinatedAppend(to url: URL, append data: Data) {
        if backend != .iCloud {
            appendBytes(data, to: url)
            return
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordError) { writeURL in
            self.appendBytes(data, to: writeURL)
        }
        if let err = coordError {
            print("⚠️ ConversationFileStore: coordinated append failed: \(err.localizedDescription)")
        }
    }

    private func appendBytes(_ data: Data, to url: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? data.write(to: url, options: [.atomic])
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            print("⚠️ ConversationFileStore: append handle write failed: \(error)")
        }
    }

    private func coordinatedRemove(_ url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        if backend != .iCloud {
            try? fm.removeItem(at: url)
            return
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: [.forDeleting], error: &coordError) { deleteURL in
            try? fm.removeItem(at: deleteURL)
        }
        if let err = coordError {
            print("⚠️ ConversationFileStore: coordinated delete failed: \(err.localizedDescription)")
        }
    }

    /// Block (briefly) until an iCloud-evicted file finishes downloading.
    /// MUST run on `ioQueue` — never call from the main thread.
    private func ensureDownloaded(_ url: URL, timeout: TimeInterval) {
        let values = try? url.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .isUbiquitousItemKey
        ])
        if values?.ubiquitousItemDownloadingStatus == .current { return }
        guard (values?.isUbiquitousItem ?? false) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if v?.ubiquitousItemDownloadingStatus == .current { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

// MARK: - Line schemas

private struct LineEnvelope: Decodable {
    let _type: String
}

private struct MetaLine: Codable {
    let _type: String
    let id: String
    let title: String
    let createdAt: Date
    let updatedAt: Date
    /// Execution backend marker. Optional so meta lines written before this
    /// field existed decode cleanly (and are treated as local on read).
    var backend: String? = nil
}

private struct MessageLineEnvelope: Encodable {
    let message: SimpleMessage

    private enum CodingKeys: String, CodingKey {
        case _type, id, role, content, name, functionName, functionArguments, actions, fileAttachment, createdAt
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("msg", forKey: ._type)
        try c.encode(message.id, forKey: .id)
        try c.encode(message.role, forKey: .role)
        try c.encode(message.content, forKey: .content)
        try c.encodeIfPresent(message.name, forKey: .name)
        try c.encodeIfPresent(message.functionName, forKey: .functionName)
        try c.encodeIfPresent(message.functionArguments, forKey: .functionArguments)
        try c.encodeIfPresent(message.actions, forKey: .actions)
        try c.encodeIfPresent(message.fileAttachment, forKey: .fileAttachment)
        try c.encode(message.createdAt, forKey: .createdAt)
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Fired (on main, debounced) when conversation data changes — locally
    /// via a write or remotely via iCloud-delivered metadata.
    static let conversationStoreDidChange = Notification.Name("ConversationStoreDidChange")

    /// Fired (on main) whenever the store's `isSyncing` may have flipped.
    /// Observers should re-read `ConversationFileStore.shared.isSyncing`.
    static let conversationStoreSyncStateChanged = Notification.Name("ConversationStoreSyncStateChanged")

    /// Posted by `SimpleConversationManager.currentConversation` when the
    /// active-conversation id changes. UserInfo carries `conversationId`
    /// (String?) so observers can compare without re-reading the manager.
    /// Surfaces like the Mac terminal pill listen to this to follow the
    /// user's tab switches across the app.
    static let activeConversationDidChange = Notification.Name("activeConversationDidChange")
}
