//
//  ExecutionBackendTests.swift
//  LoopIOSTests
//
//  Unit tests for the OpenClaw execution-backend work: backend-selection
//  persistence, conversation backend marking, the conversation store router's
//  routing + graceful fallback, the OpenClaw NDJSON wire format, and shell
//  path/quoting safety. Uses in-memory fake stores so nothing here touches SSH
//  or the Keychain.
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
    func removeMessage(id messageId: String, fromConversation conversationId: String) {
        guard var conv = store[conversationId] else { return }
        conv.messages.removeAll { $0.id == messageId }
        store[conversationId] = conv
    }

    // Test helper to seed without going through the public API.
    func seed(_ conv: SimpleConversation) { store[conv.id] = conv }
}

// MARK: - Backend selection persistence

final class ExecutionBackendStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ExecutionBackendStore.shared.selectedBackend = .local
        ExecutionBackendStore.shared.openClawValidated = false
    }

    override func tearDown() {
        ExecutionBackendStore.shared.selectedBackend = .local
        ExecutionBackendStore.shared.openClawValidated = false
        super.tearDown()
    }

    func testDefaultsToLocal() {
        XCTAssertEqual(ExecutionBackendStore.shared.selectedBackend, .local)
    }

    func testSelectionPersists() {
        ExecutionBackendStore.shared.selectedBackend = .openclaw
        XCTAssertEqual(ExecutionBackendStore.shared.selectedBackend, .openclaw)
        ExecutionBackendStore.shared.selectedBackend = .local
        XCTAssertEqual(ExecutionBackendStore.shared.selectedBackend, .local)
    }

    func testValidatedFlagPersists() {
        XCTAssertFalse(ExecutionBackendStore.shared.openClawValidated)
        ExecutionBackendStore.shared.openClawValidated = true
        XCTAssertTrue(ExecutionBackendStore.shared.openClawValidated)
    }

    func testNotActiveWhenLocalSelected() {
        // Local selected → never active regardless of config/validation.
        ExecutionBackendStore.shared.selectedBackend = .local
        ExecutionBackendStore.shared.openClawValidated = true
        XCTAssertFalse(ExecutionBackendStore.shared.isOpenClawActive)
    }
}

// MARK: - Conversation backend marking

final class ConversationBackendMarkingTests: XCTestCase {

    func testNilBackendIsLocal() {
        let conv = SimpleConversation(title: "Test")
        XCTAssertNil(conv.backend)
        XCTAssertEqual(conv.backendKind, .local)
    }

    func testOpenClawMarkerMapsToOpenClaw() {
        let conv = SimpleConversation(title: "Test", backend: "openclaw")
        XCTAssertEqual(conv.backendKind, .openclaw)
    }

    func testUnknownMarkerFallsBackToLocal() {
        let conv = SimpleConversation(title: "Test", backend: "martian")
        XCTAssertEqual(conv.backendKind, .local)
    }

    func testBackendSurvivesCodableRoundTrip() throws {
        let original = SimpleConversation(title: "Test", backend: "openclaw")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SimpleConversation.self, from: data)
        XCTAssertEqual(decoded.backend, "openclaw")
        XCTAssertEqual(decoded.backendKind, .openclaw)
    }

    func testLegacyJSONWithoutBackendDecodesAsLocal() throws {
        // A conversation persisted before the `backend` field existed.
        let json = """
        {"id":"abc","title":"Old","messages":[],"createdAt":0,"updatedAt":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SimpleConversation.self, from: json)
        XCTAssertNil(decoded.backend)
        XCTAssertEqual(decoded.backendKind, .local)
    }
}

// MARK: - Router routing + fallback

final class ConversationStoreRouterTests: XCTestCase {

    private func makeRouter(openClawActive: Bool)
        -> (ConversationStoreRouter, FakeConversationStore, FakeConversationStore) {
        let local = FakeConversationStore(marker: "local")
        let openClaw = FakeConversationStore(marker: "openclaw")
        let router = ConversationStoreRouter(
            local: local, openClaw: openClaw, isOpenClawActive: { openClawActive })
        return (router, local, openClaw)
    }

    func testNewConversationGoesLocalWhenOpenClawInactive() {
        let (router, local, openClaw) = makeRouter(openClawActive: false)
        let conv = router.createConversation(title: "Hi")
        XCTAssertEqual(conv.backendKind, .local)
        XCTAssertNotNil(local.conversation(id: conv.id))
        XCTAssertNil(openClaw.conversation(id: conv.id))
    }

    func testNewConversationGoesOpenClawWhenActive() {
        let (router, local, openClaw) = makeRouter(openClawActive: true)
        let conv = router.createConversation(title: "Hi")
        XCTAssertEqual(conv.backendKind, .openclaw)
        XCTAssertNotNil(openClaw.conversation(id: conv.id))
        XCTAssertNil(local.conversation(id: conv.id))
    }

    func testFallbackToLocalWhenOpenClawStoreMissing() {
        let local = FakeConversationStore(marker: "local")
        let router = ConversationStoreRouter(
            local: local, openClaw: nil, isOpenClawActive: { true })
        let conv = router.createConversation(title: "Hi")
        XCTAssertEqual(conv.backendKind, .local)
    }

    func testMessageRoutesToOwningStore() {
        let (router, local, openClaw) = makeRouter(openClawActive: true)
        // A pre-existing local conversation.
        let localConv = local.createConversation(title: "Local")
        // A new openclaw conversation.
        let remoteConv = router.createConversation(title: "Remote")

        router.addMessage(SimpleMessage(role: "user", content: "to-local"), toConversation: localConv.id)
        router.addMessage(SimpleMessage(role: "user", content: "to-remote"), toConversation: remoteConv.id)

        XCTAssertEqual(local.messages(forConversation: localConv.id).first?.content, "to-local")
        XCTAssertEqual(openClaw.messages(forConversation: remoteConv.id).first?.content, "to-remote")
        // No cross-contamination.
        XCTAssertTrue(openClaw.messages(forConversation: localConv.id).isEmpty)
    }

    func testAllConversationsMergesAndSortsByUpdatedAt() {
        let (router, local, openClaw) = makeRouter(openClawActive: true)
        let old = SimpleConversation(title: "Old", createdAt: Date(timeIntervalSince1970: 100),
                                     updatedAt: Date(timeIntervalSince1970: 100), backend: "local")
        let new = SimpleConversation(title: "New", createdAt: Date(timeIntervalSince1970: 200),
                                     updatedAt: Date(timeIntervalSince1970: 200), backend: "openclaw")
        local.seed(old)
        openClaw.seed(new)
        let all = router.allConversations()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.title, "New") // newest first
        XCTAssertEqual(all.last?.title, "Old")
    }

    func testMostRecentlyUpdatedAcrossBackends() {
        let (router, local, openClaw) = makeRouter(openClawActive: true)
        local.seed(SimpleConversation(title: "L", updatedAt: Date(timeIntervalSince1970: 50), backend: "local"))
        openClaw.seed(SimpleConversation(title: "O", updatedAt: Date(timeIntervalSince1970: 99), backend: "openclaw"))
        XCTAssertEqual(router.mostRecentlyUpdatedConversation()?.title, "O")
    }

    func testExistingLocalConversationStaysLocalEvenWhenOpenClawActive() {
        let (router, local, openClaw) = makeRouter(openClawActive: true)
        let localConv = local.createConversation(title: "Existing")
        // Saving / messaging an existing local conversation must not migrate it.
        router.addMessage(SimpleMessage(role: "user", content: "hi"), toConversation: localConv.id)
        XCTAssertNotNil(local.conversation(id: localConv.id))
        XCTAssertNil(openClaw.conversation(id: localConv.id))
    }
}

// MARK: - OpenClaw config + wire format

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

    func testConversationsDirExpressionExpandsTilde() {
        let cfg = OpenClawConfig(workspacePath: "~/loop-workspace")
        let expr = OpenClawConversationStore.conversationsDirExpression(for: cfg)
        XCTAssertEqual(expr, "\"$HOME\"/'loop-workspace'/conversations")
    }

    func testConversationsDirExpressionQuotesAbsolutePath() {
        let cfg = OpenClawConfig(workspacePath: "/srv/loop work")
        let expr = OpenClawConversationStore.conversationsDirExpression(for: cfg)
        XCTAssertEqual(expr, "'/srv/loop work'/conversations")
    }

    func testShQuoteEscapesSingleQuotes() {
        XCTAssertEqual(OpenClawConversationStore.shQuote("a'b"), "'a'\\''b'")
    }

    func testParseNDJSONRoundTrip() {
        // Build a minimal NDJSON blob the way the store writes it.
        let meta = "{\"_type\":\"meta\",\"id\":\"c1\",\"title\":\"Hello\",\"createdAt\":\"2024-01-01T00:00:00Z\",\"updatedAt\":\"2024-01-02T00:00:00Z\",\"backend\":\"openclaw\"}"
        let msg = "{\"_type\":\"msg\",\"id\":\"m1\",\"role\":\"user\",\"content\":\"hi\",\"createdAt\":\"2024-01-01T00:00:01Z\"}"
        let text = meta + "\n" + msg + "\n"
        let conv = OpenClawConversationStore.parseNDJSON(text, fallbackId: "c1")
        XCTAssertNotNil(conv)
        XCTAssertEqual(conv?.title, "Hello")
        XCTAssertEqual(conv?.backend, "openclaw")
        XCTAssertEqual(conv?.messages.count, 1)
        XCTAssertEqual(conv?.messages.first?.content, "hi")
    }

    func testParseFramedListingDecodesMultipleFiles() {
        let ndjson1 = "{\"_type\":\"meta\",\"id\":\"a\",\"title\":\"A\",\"createdAt\":\"2024-01-01T00:00:00Z\",\"updatedAt\":\"2024-01-01T00:00:00Z\"}\n"
        let ndjson2 = "{\"_type\":\"meta\",\"id\":\"b\",\"title\":\"B\",\"createdAt\":\"2024-01-01T00:00:00Z\",\"updatedAt\":\"2024-01-01T00:00:00Z\"}\n"
        let b1 = Data(ndjson1.utf8).base64EncodedString()
        let b2 = Data(ndjson2.utf8).base64EncodedString()
        let output = "===OPENCLAW:a.ndjson===\n\(b1)\n===OPENCLAW:b.ndjson===\n\(b2)\n"
        let convs = OpenClawConversationStore.parseFramedListing(output)
        XCTAssertEqual(convs.count, 2)
        XCTAssertEqual(Set(convs.map { $0.title }), ["A", "B"])
        // Files framed under their id (filename without extension).
        XCTAssertEqual(Set(convs.map { $0.id }), ["a", "b"])
    }
}
