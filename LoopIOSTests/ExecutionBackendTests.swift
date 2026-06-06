//
//  ExecutionBackendTests.swift
//  LoopIOSTests
//
//  Unit tests for the execution-backend list: backend persistence (add / delete
//  / select / Local-not-deletable), per-backend validation, the conversation
//  store router's routing + per-backend isolation + graceful fallback, the
//  NDJSON wire format, and shell path/quoting safety. Uses in-memory fake stores
//  so nothing here touches SSH or the Keychain.
//

import XCTest
@testable import Loop

// MARK: - Fake store

/// In-memory `ConversationStore` for router tests.
private final class FakeConversationStore: ConversationStore {
    let backendMarker: String
    var isSyncing: Bool = false
    private var store: [String: SimpleConversation] = [:]

    init(marker: String) { self.backendMarker = marker }

    func allConversations() -> [SimpleConversation] {
        store.values.sorted { $0.updatedAt > $1.updatedAt }
    }
    func conversation(id: String) -> SimpleConversation? { store[id] }
    func mostRecentlyUpdatedConversation() -> SimpleConversation? {
        store.values.max { $0.updatedAt < $1.updatedAt }
    }
    func messages(forConversation id: String) -> [SimpleMessage] { store[id]?.messages ?? [] }

    func createConversation(title: String) -> SimpleConversation {
        let conv = SimpleConversation(title: title, backend: backendMarker)
        store[conv.id] = conv
        return conv
    }
    func saveConversation(_ conversation: SimpleConversation) { store[conversation.id] = conversation }
    func deleteConversation(id: String) { store[id] = nil }
    func addMessage(_ message: SimpleMessage, toConversation id: String) {
        var conv = store[id] ?? SimpleConversation(id: id, title: "Untitled", backend: backendMarker)
        conv.messages.append(message)
        conv.updatedAt = Date()
        store[id] = conv
    }
    func updateMessage(_ message: SimpleMessage, inConversation conversationId: String) {
        guard var conv = store[conversationId],
              let idx = conv.messages.firstIndex(where: { $0.id == message.id }) else { return }
        conv.messages[idx] = message
        conv.updatedAt = Date()
        store[conversationId] = conv
    }
    func removeMessage(id messageId: String, fromConversation conversationId: String) {
        guard var conv = store[conversationId] else { return }
        conv.messages.removeAll { $0.id == messageId }
        store[conversationId] = conv
    }

    // Test helper to seed without going through the public API.
    func seed(_ conv: SimpleConversation) { store[conv.id] = conv }
}

// MARK: - Backend store (list + selection + validation)

final class ExecutionBackendStoreTests: XCTestCase {

    private let store = ExecutionBackendStore.shared

    override func setUp() {
        super.setUp()
        resetStore()
    }

    override func tearDown() {
        resetStore()
        super.tearDown()
    }

    /// Remove every remote backend and reset selection so tests don't bleed.
    private func resetStore() {
        for backend in store.remoteBackends {
            store.delete(id: backend.id)
        }
        store.select(id: ExecutionBackend.localID)
    }

    func testStartsWithLocalOnly() {
        XCTAssertEqual(store.backends.count, 1)
        XCTAssertEqual(store.backends.first?.id, ExecutionBackend.localID)
        XCTAssertTrue(store.remoteBackends.isEmpty)
    }

    func testDefaultsToLocalSelected() {
        XCTAssertEqual(store.selectedBackendID, ExecutionBackend.localID)
        XCTAssertTrue(store.selectedBackend.isLocal)
    }

    func testLocalIsNotDeletable() {
        XCTAssertFalse(ExecutionBackend.local.isDeletable)
        // Deleting Local is a no-op.
        store.delete(id: ExecutionBackend.localID)
        XCTAssertNotNil(store.backend(id: ExecutionBackend.localID))
    }

    func testAddRemoteBackend() {
        let backend = ExecutionBackend(name: "VM A", config: configured(host: "a"))
        store.addOrUpdate(backend)
        XCTAssertEqual(store.remoteBackends.count, 1)
        XCTAssertEqual(store.backends.count, 2)
        XCTAssertEqual(store.backend(id: backend.id)?.name, "VM A")
        XCTAssertTrue(store.backend(id: backend.id)!.isDeletable)
    }

    func testUpdateRemoteInPlace() {
        var backend = ExecutionBackend(name: "VM A", config: configured(host: "a"))
        store.addOrUpdate(backend)
        backend.name = "VM A renamed"
        store.addOrUpdate(backend)
        XCTAssertEqual(store.remoteBackends.count, 1)
        XCTAssertEqual(store.backend(id: backend.id)?.name, "VM A renamed")
    }

    func testDeleteRemoteBackend() {
        let backend = ExecutionBackend(name: "VM A", config: configured(host: "a"))
        store.addOrUpdate(backend)
        store.delete(id: backend.id)
        XCTAssertTrue(store.remoteBackends.isEmpty)
        XCTAssertNil(store.backend(id: backend.id))
    }

    func testDeletingSelectedBackendFallsBackToLocal() {
        let backend = ExecutionBackend(name: "VM A", config: configured(host: "a"))
        store.addOrUpdate(backend)
        store.setValidated(true, for: backend.id)
        store.select(id: backend.id)
        XCTAssertEqual(store.selectedBackendID, backend.id)

        store.delete(id: backend.id)
        XCTAssertEqual(store.selectedBackendID, ExecutionBackend.localID)
    }

    func testSelectionPersists() {
        let backend = ExecutionBackend(name: "VM A", config: configured(host: "a"))
        store.addOrUpdate(backend)
        store.select(id: backend.id)
        XCTAssertEqual(store.selectedBackendID, backend.id)
    }

    func testValidationIsPerBackend() {
        let a = ExecutionBackend(name: "A", config: configured(host: "a"))
        let b = ExecutionBackend(name: "B", config: configured(host: "b"))
        store.addOrUpdate(a)
        store.addOrUpdate(b)
        store.setValidated(true, for: a.id)
        XCTAssertTrue(store.isValidated(id: a.id))
        XCTAssertFalse(store.isValidated(id: b.id))
    }

    func testActiveRemoteRequiresSelectedConfiguredAndValidated() {
        let backend = ExecutionBackend(name: "A", config: configured(host: "a"))
        store.addOrUpdate(backend)

        // Selected but not validated → local is active.
        store.select(id: backend.id)
        XCTAssertNil(store.activeRemoteBackendID)

        // Validated + selected → active.
        store.setValidated(true, for: backend.id)
        XCTAssertEqual(store.activeRemoteBackendID, backend.id)

        // Selecting Local again deactivates the remote.
        store.select(id: ExecutionBackend.localID)
        XCTAssertNil(store.activeRemoteBackendID)
    }

    func testUnconfiguredRemoteNeverActive() {
        let backend = ExecutionBackend(name: "A", config: OpenClawConfig(host: "a")) // missing fields
        store.addOrUpdate(backend)
        store.select(id: backend.id)
        store.setValidated(true, for: backend.id)
        XCTAssertNil(store.activeRemoteBackendID)
    }

    private func configured(host: String) -> OpenClawConfig {
        OpenClawConfig(host: host, username: "u", privateKey: "k", workspacePath: "~/w")
    }
}

// MARK: - Image attachment persistence

final class ImageAttachmentPersistenceTests: XCTestCase {

    func testReadyAttachmentRoundTrips() throws {
        let url = URL(fileURLWithPath: "/tmp/images/abc.png")
        let original = ImageAttachment(id: "abc", prompt: "a cat",
                                       fileURL: url, status: .ready,
                                       conversationId: "conv-1")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ImageAttachment.self, from: data)
        XCTAssertEqual(decoded.id, "abc")
        XCTAssertEqual(decoded.prompt, "a cat")
        XCTAssertEqual(decoded.fileURL, url)
        XCTAssertEqual(decoded.status, .ready)
        XCTAssertEqual(decoded.conversationId, "conv-1")
    }

    func testStatusRawValuesAreStable() throws {
        // Status persists as a string; guard against an accidental rename
        // changing the on-disk representation.
        XCTAssertEqual(ImageAttachment.Status.generating.rawValue, "generating")
        XCTAssertEqual(ImageAttachment.Status.ready.rawValue, "ready")
        XCTAssertEqual(ImageAttachment.Status.failed.rawValue, "failed")
    }

    func testGeneratingAttachmentRoundTripsForLaterReconciliation() throws {
        // An in-flight placeholder must persist as `.generating` so the host's
        // cold-launch sweep can later reconcile it to a retryable failure.
        let original = ImageAttachment(id: "x", prompt: "p", status: .generating)
        let decoded = try JSONDecoder().decode(ImageAttachment.self,
                                               from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.status, .generating)
    }
}

// MARK: - Conversation backend marking

final class ConversationBackendMarkingTests: XCTestCase {

    func testNilBackendIsLocal() {
        let conv = SimpleConversation(title: "Test")
        XCTAssertNil(conv.backend)
        XCTAssertEqual(conv.backendKind, .local)
    }

    func testLocalMarkerIsLocal() {
        let conv = SimpleConversation(title: "Test", backend: ExecutionBackend.localID)
        XCTAssertEqual(conv.backendKind, .local)
    }

    func testRemoteIdMarkerIsRemote() {
        let conv = SimpleConversation(title: "Test", backend: "openclaw")
        XCTAssertEqual(conv.backendKind, .remote)
        let conv2 = SimpleConversation(title: "Test", backend: UUID().uuidString)
        XCTAssertEqual(conv2.backendKind, .remote)
    }

    func testBackendSurvivesCodableRoundTrip() throws {
        let original = SimpleConversation(title: "Test", backend: "some-vm-id")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SimpleConversation.self, from: data)
        XCTAssertEqual(decoded.backend, "some-vm-id")
        XCTAssertEqual(decoded.backendKind, .remote)
    }

    func testLegacyJSONWithoutBackendDecodesAsLocal() throws {
        let json = """
        {"id":"abc","title":"Old","messages":[],"createdAt":0,"updatedAt":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SimpleConversation.self, from: json)
        XCTAssertNil(decoded.backend)
        XCTAssertEqual(decoded.backendKind, .local)
    }
}

// MARK: - Router routing + per-backend isolation + fallback

final class ConversationStoreRouterTests: XCTestCase {

    /// Builds a router with the local store plus N named remote stores. The
    /// `active` id (if any) is the active remote backend.
    private func makeRouter(remoteIDs: [String], active: String?)
        -> (ConversationStoreRouter, FakeConversationStore, [String: FakeConversationStore]) {
        let local = FakeConversationStore(marker: ExecutionBackend.localID)
        var remotes: [String: ConversationStore] = [:]
        var fakes: [String: FakeConversationStore] = [:]
        for id in remoteIDs {
            let store = FakeConversationStore(marker: id)
            remotes[id] = store
            fakes[id] = store
        }
        let router = ConversationStoreRouter(
            local: local, remotes: remotes, activeRemoteID: { active })
        return (router, local, fakes)
    }

    func testNewConversationGoesLocalWhenNoRemoteActive() {
        let (router, local, fakes) = makeRouter(remoteIDs: ["vm1"], active: nil)
        let conv = router.createConversation(title: "Hi")
        XCTAssertEqual(conv.backendKind, .local)
        XCTAssertNotNil(local.conversation(id: conv.id))
        XCTAssertNil(fakes["vm1"]?.conversation(id: conv.id))
    }

    func testNewConversationGoesToActiveRemote() {
        let (router, local, fakes) = makeRouter(remoteIDs: ["vm1"], active: "vm1")
        let conv = router.createConversation(title: "Hi")
        XCTAssertEqual(conv.backend, "vm1")
        XCTAssertNotNil(fakes["vm1"]?.conversation(id: conv.id))
        XCTAssertNil(local.conversation(id: conv.id))
    }

    func testFallbackToLocalWhenActiveRemoteMissing() {
        // Active id names a remote that isn't wired up.
        let (router, _, _) = makeRouter(remoteIDs: [], active: "ghost")
        let conv = router.createConversation(title: "Hi")
        XCTAssertEqual(conv.backendKind, .local)
    }

    func testConversationsStayPinnedToTheirOwnRemote() {
        // Two remotes; vm2 is active. A conversation that already lives on vm1
        // must keep routing to vm1, not migrate to the active vm2.
        let (router, _, fakes) = makeRouter(remoteIDs: ["vm1", "vm2"], active: "vm2")
        let onVM1 = fakes["vm1"]!.createConversation(title: "On VM1")

        router.addMessage(SimpleMessage(role: "user", content: "still vm1"), toConversation: onVM1.id)
        let newConv = router.createConversation(title: "New") // goes to active vm2

        XCTAssertEqual(fakes["vm1"]?.messages(forConversation: onVM1.id).first?.content, "still vm1")
        XCTAssertTrue(fakes["vm2"]!.messages(forConversation: onVM1.id).isEmpty)
        XCTAssertNotNil(fakes["vm2"]?.conversation(id: newConv.id))
        XCTAssertNil(fakes["vm1"]?.conversation(id: newConv.id))
    }

    func testMessageRoutesToOwningStore() {
        let (router, local, fakes) = makeRouter(remoteIDs: ["vm1"], active: "vm1")
        let localConv = local.createConversation(title: "Local")
        let remoteConv = router.createConversation(title: "Remote")

        router.addMessage(SimpleMessage(role: "user", content: "to-local"), toConversation: localConv.id)
        router.addMessage(SimpleMessage(role: "user", content: "to-remote"), toConversation: remoteConv.id)

        XCTAssertEqual(local.messages(forConversation: localConv.id).first?.content, "to-local")
        XCTAssertEqual(fakes["vm1"]?.messages(forConversation: remoteConv.id).first?.content, "to-remote")
        XCTAssertTrue(fakes["vm1"]!.messages(forConversation: localConv.id).isEmpty)
    }

    func testListShowsOnlyActiveRemoteSortedByUpdatedAt() {
        // Joining a remote backend replaces the list with that backend's
        // sessions; local conversations are hidden, not merged in.
        let (router, local, fakes) = makeRouter(remoteIDs: ["vm1"], active: "vm1")
        local.seed(SimpleConversation(title: "LocalHidden", updatedAt: Date(timeIntervalSince1970: 500), backend: "local"))
        fakes["vm1"]!.seed(SimpleConversation(title: "Old", updatedAt: Date(timeIntervalSince1970: 100), backend: "vm1"))
        fakes["vm1"]!.seed(SimpleConversation(title: "New", updatedAt: Date(timeIntervalSince1970: 200), backend: "vm1"))
        let all = router.allConversations()
        XCTAssertEqual(all.map(\.title), ["New", "Old"]) // only vm1, newest first
        XCTAssertFalse(all.contains { $0.title == "LocalHidden" })
    }

    func testListShowsOnlyLocalWhenNoRemoteActive() {
        // Switching back to Local restores the on-device list and hides remotes.
        let (router, local, fakes) = makeRouter(remoteIDs: ["vm1"], active: nil)
        local.seed(SimpleConversation(title: "L", updatedAt: Date(timeIntervalSince1970: 10), backend: "local"))
        fakes["vm1"]!.seed(SimpleConversation(title: "R", updatedAt: Date(timeIntervalSince1970: 20), backend: "vm1"))
        let all = router.allConversations()
        XCTAssertEqual(all.map(\.title), ["L"])
    }

    func testActiveRemoteConversationStillResolvesHiddenLocalById() {
        // A conversation owned by a now-hidden backend must still load by id so
        // an in-flight chat isn't lost when the user switches backends.
        let (router, local, _) = makeRouter(remoteIDs: ["vm1"], active: "vm1")
        let hidden = SimpleConversation(title: "InFlight", backend: "local")
        local.seed(hidden)
        XCTAssertNil(router.allConversations().first { $0.id == hidden.id }) // hidden from list
        XCTAssertEqual(router.conversation(id: hidden.id)?.title, "InFlight") // but resolvable by id
    }

    func testMostRecentlyUpdatedFollowsActiveBackend() {
        let (router, local, fakes) = makeRouter(remoteIDs: ["vm1"], active: "vm1")
        local.seed(SimpleConversation(title: "L", updatedAt: Date(timeIntervalSince1970: 999), backend: "local"))
        fakes["vm1"]!.seed(SimpleConversation(title: "O", updatedAt: Date(timeIntervalSince1970: 99), backend: "vm1"))
        // Even though Local "L" is newer overall, the active backend is vm1.
        XCTAssertEqual(router.mostRecentlyUpdatedConversation()?.title, "O")
    }

    func testSetRemotesSwapsStoresAtRuntime() {
        let (router, _, _) = makeRouter(remoteIDs: [], active: "vm1")
        let vm1 = FakeConversationStore(marker: "vm1")
        router.setRemotes(["vm1": vm1])
        let conv = router.createConversation(title: "Hi")
        XCTAssertNotNil(vm1.conversation(id: conv.id))
    }
}

// MARK: - OpenClawConfig + wire format

final class OpenClawConfigTests: XCTestCase {

    func testIsConfiguredRequiresAllFields() {
        XCTAssertFalse(OpenClawConfig().isConfigured)
        XCTAssertFalse(OpenClawConfig(host: "h", username: "u", privateKey: "k").isConfigured) // no workspace
        XCTAssertTrue(OpenClawConfig(host: "h", username: "u", privateKey: "k", workspacePath: "~/w").isConfigured)
    }

    func testTrimmedWorkspaceStripsTrailingSlash() {
        let cfg = OpenClawConfig(workspacePath: "  /home/me/loop/  ")
        XCTAssertEqual(cfg.trimmedWorkspacePath, "/home/me/loop")
    }

    func testDefaultAgentIdIsMain() {
        XCTAssertEqual(OpenClawConfig().trimmedAgentId, "main")
        XCTAssertEqual(OpenClawConfig(agentId: "  ").trimmedAgentId, "main")
        XCTAssertEqual(OpenClawConfig(agentId: " ops ").trimmedAgentId, "ops")
    }

    func testSessionsDirExpressionUsesAgentId() {
        let cfg = OpenClawConfig(agentId: "ops")
        let expr = OpenClawConversationStore.sessionsDirExpression(for: cfg)
        XCTAssertEqual(expr, "\"$HOME\"/.openclaw/agents/'ops'/sessions")
    }

    func testSessionFileExpressionAppendsJSONL() {
        let cfg = OpenClawConfig(agentId: "main")
        let expr = OpenClawConversationStore.sessionFileExpression(for: cfg, sessionId: "abc-123")
        XCTAssertEqual(expr, "\"$HOME\"/.openclaw/agents/'main'/sessions/'abc-123.jsonl'")
    }

    func testShQuoteEscapesSingleQuotes() {
        XCTAssertEqual(OpenClawConversationStore.shQuote("a'b"), "'a'\\''b'")
    }

    func testParseNDJSONRoundTrip() {
        let meta = "{\"_type\":\"meta\",\"id\":\"c1\",\"title\":\"Hello\",\"createdAt\":\"2024-01-01T00:00:00Z\",\"updatedAt\":\"2024-01-02T00:00:00Z\",\"backend\":\"vm-1\"}"
        let msg = "{\"_type\":\"msg\",\"id\":\"m1\",\"role\":\"user\",\"content\":\"hi\",\"createdAt\":\"2024-01-01T00:00:01Z\"}"
        let text = meta + "\n" + msg + "\n"
        let conv = OpenClawConversationStore.parseNDJSON(text, fallbackId: "c1", defaultBackend: "vm-1")
        XCTAssertNotNil(conv)
        XCTAssertEqual(conv?.title, "Hello")
        XCTAssertEqual(conv?.backend, "vm-1")
        XCTAssertEqual(conv?.messages.count, 1)
        XCTAssertEqual(conv?.messages.first?.content, "hi")
    }

    func testParseNDJSONUsesDefaultBackendWhenMetaOmitsIt() {
        // A meta line written before the backend field existed.
        let meta = "{\"_type\":\"meta\",\"id\":\"c1\",\"title\":\"Hello\",\"createdAt\":\"2024-01-01T00:00:00Z\",\"updatedAt\":\"2024-01-02T00:00:00Z\"}"
        let conv = OpenClawConversationStore.parseNDJSON(meta + "\n", fallbackId: "c1", defaultBackend: "vm-7")
        XCTAssertEqual(conv?.backend, "vm-7")
    }

    // MARK: OpenClaw CLI parsing

    func testParseSessionsListMapsRowsAndFiltersMachineSessions() {
        // Mirrors `openclaw sessions --json` shape; tolerates a leading sentinel.
        let json = """
        OPENCLAW_OK
        {"path":"/h/.openclaw/agents/main/sessions/sessions.json","count":3,"sessions":[
          {"key":"agent:main:main","sessionId":"s-main","updatedAt":1780378275059,"agentId":"main","kind":"direct"},
          {"key":"agent:main:cron:abc","sessionId":"s-cron","updatedAt":1780379294828,"agentId":"main","kind":"direct"},
          {"key":"agent:main:cron:abc:run:def","sessionId":"s-run","updatedAt":1780379266170,"agentId":"main","kind":"direct"}
        ]}
        """
        let convs = OpenClawConversationStore.parseSessionsList(json, defaultBackend: "vm-1")
        // cron + run sub-sessions filtered out; only the real chat remains.
        XCTAssertEqual(convs.map { $0.id }, ["s-main"])
        XCTAssertEqual(convs.first?.title, "Main")
        XCTAssertEqual(convs.first?.backend, "vm-1")
        XCTAssertEqual(convs.first?.updatedAt, Date(timeIntervalSince1970: 1780378275.059))
    }

    func testParseSessionsListDedupsBySessionIdKeepingNewest() {
        let json = """
        {"sessions":[
          {"key":"agent:main:telegram:1","sessionId":"dup","updatedAt":100000},
          {"key":"agent:main:telegram:1","sessionId":"dup","updatedAt":200000}
        ]}
        """
        let convs = OpenClawConversationStore.parseSessionsList(json, defaultBackend: "vm-1")
        XCTAssertEqual(convs.count, 1)
        XCTAssertEqual(convs.first?.updatedAt, Date(timeIntervalSince1970: 200))
    }

    func testDeriveTitleHumanizesKey() {
        XCTAssertEqual(OpenClawConversationStore.deriveTitle(fromKey: "agent:main:main", agentId: "main"), "Main")
        XCTAssertEqual(
            OpenClawConversationStore.deriveTitle(fromKey: "agent:main:telegram:direct:123", agentId: "main"),
            "Telegram · direct · 123")
    }

    func testParseSessionTranscriptMapsContentBlocks() {
        // Real OpenClaw transcript shape: a session header line then message
        // events with Anthropic-style content blocks.
        let jsonl = """
        {"type":"session","version":3,"id":"s1","timestamp":"2026-05-31T16:02:51.908Z"}
        {"type":"message","id":"u1","message":{"role":"user","content":[{"type":"text","text":"hi there"}],"timestamp":1780243371000}}
        {"type":"message","id":"a1","message":{"role":"assistant","content":[{"type":"text","text":"hello back"}],"model":"gpt-5.2","timestamp":1780243371908}}
        {"type":"message","id":"t1","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_1","name":"bash","input":{"command":"uname -a"}}],"timestamp":1780243372000}}
        """
        let msgs = OpenClawConversationStore.parseSessionTranscript(jsonl, sessionId: "s1")
        // The session line is dropped; the text-less tool_use turn is kept so the
        // "Used N tools" disclosure renders.
        XCTAssertEqual(msgs.map { $0.id }, ["u1", "a1", "t1"])
        XCTAssertEqual(msgs.map { $0.role }, ["user", "assistant", "assistant"])
        XCTAssertEqual(msgs.first?.content, "hi there")
        XCTAssertEqual(msgs[1].content, "hello back")
        XCTAssertEqual(msgs[1].model, "gpt-5.2")
        // The tool-only turn carries no text but encodes the call in functionCallsJSON.
        XCTAssertEqual(msgs.last?.content, "")
        let calls = msgs.last?.functionCallsJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
        XCTAssertEqual(calls?.count, 1)
        XCTAssertEqual(calls?.first?["name"] as? String, "bash")
        XCTAssertEqual(calls?.first?["callId"] as? String, "call_1")
        XCTAssertEqual((calls?.first?["arguments"] as? [String: Any])?["command"] as? String, "uname -a")
    }

    func testParseSessionTranscriptHandlesStringContentAndSkipsBadLines() {
        let jsonl = """
        not json at all
        {"type":"message","id":"a1","message":{"role":"assistant","content":"plain string","model":"delivery-mirror","timestamp":1780243371908}}
        """
        let msgs = OpenClawConversationStore.parseSessionTranscript(jsonl, sessionId: "s1")
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs.first?.content, "plain string")
        // `delivery-mirror` is an internal echo, not a user-facing model badge.
        XCTAssertNil(msgs.first?.model)
    }

    func testParseAgentResultReturnsNilWhileRunning() {
        // Empty / partial log (no completion marker) ⇒ still running.
        XCTAssertNil(OpenClawConversationStore.parseAgentResult(""))
        XCTAssertNil(OpenClawConversationStore.parseAgentResult("{\"status\":\"ok\""))
    }

    func testParseAgentResultExtractsReplyAndSessionId() {
        // Shape mirrors a real `openclaw agent --json` run log + completion marker.
        let log = """
        {"runId":"run-1","status":"ok","summary":"completed","result":{"payloads":[{"text":"Hey — what can I help with?","mediaUrl":null}],"meta":{"durationMs":7498,"agentMeta":{"sessionId":"4b742ba8","model":"us.anthropic.claude-opus-4-6-v1"},"stopReason":"stop"}}}
        LOOPDONE:0
        """
        let outcome = OpenClawConversationStore.parseAgentResult(log)
        XCTAssertEqual(outcome?.ok, true)
        XCTAssertEqual(outcome?.reply, "Hey — what can I help with?")
        XCTAssertEqual(outcome?.sessionId, "4b742ba8")
        XCTAssertEqual(outcome?.model, "us.anthropic.claude-opus-4-6-v1")
        XCTAssertEqual(outcome?.messageId, "run-1")
        XCTAssertEqual(outcome?.durationSeconds ?? 0, 7.498, accuracy: 0.001)
    }

    func testParseAgentResultFlagsNonZeroExitAsFailure() {
        let log = "openclaw: command failed\nLOOPDONE:1"
        let outcome = OpenClawConversationStore.parseAgentResult(log)
        XCTAssertEqual(outcome?.ok, false)
        XCTAssertNotNil(outcome?.error)
    }
}
