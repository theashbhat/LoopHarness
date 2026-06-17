//
//  ConversationView.swift
//  LoopVision
//
//  The visionOS rethink of the Mac's NSSplitViewController conversation
//  window. Opened as a separate 2D window when the pill below the orb is
//  tapped, so it sits alongside the orb (and every other app) in the Shared
//  Space. A SwiftUI NavigationSplitView: conversations on the left, the
//  selected transcript on the right, rendered with native markdown.
//
//  History is the shared, iCloud-synced SimpleConversationManager store, so
//  the list and transcripts match what the iPhone and Mac show. Selecting a
//  conversation tells the session to continue voice turns in it.
//

import SwiftUI
import MapKit

struct ConversationView: View {
    let session: VisionSession

    @State private var selectedID: String?
    @State private var showSubAgentInspector: Bool = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onAppear {
            session.reloadConversations()
            if selectedID == nil { selectedID = session.currentConversationID }
        }
        .onChange(of: selectedID) { _, newID in
            guard let newID, newID != session.currentConversationID,
                  let conv = session.conversations.first(where: { $0.id == newID })
            else { return }
            session.selectConversation(conv)
        }
        .sheet(isPresented: $showSubAgentInspector) {
            SubAgentInspectorSheet(session: session, conversationId: selectedID)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedID) {
            ForEach(session.conversations, id: \.id) { conv in
                VStack(alignment: .leading, spacing: 4) {
                    Text(conv.title.isEmpty ? "Untitled" : conv.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(conv.updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(conv.id)
            }
        }
        .navigationTitle("Conversations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let conv = SimpleConversationManager.shared.createConversation(
                        title: "Vision Chat \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))")
                    session.reloadConversations()
                    selectedID = conv.id
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                }
            }
        }
    }

    // MARK: - Detail (transcript)

    @ViewBuilder
    private var detail: some View {
        // Touching turnCounter establishes an observation dependency so the
        // transcript re-reads the store after each completed voice turn.
        let _ = session.turnCounter
        VStack(spacing: 0) {
            // Sub-agent pill: sits above the transcript when any native /
            // Devin / Cursor agent is tracked for the selected conversation,
            // mirroring iPhone's `SubAgentStatusBarView` placement above the
            // MessagingVC table.
            SubAgentPill(session: session, conversationId: selectedID) {
                showSubAgentInspector = true
            }
            .padding(.top, 8)

            transcriptArea
        }
    }

    @ViewBuilder
    private var transcriptArea: some View {
        if let id = selectedID {
            let messages = Self.transcript(for: id)
            if messages.isEmpty {
                ContentUnavailableView("No messages yet",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Look at the orb and pinch to talk."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(messages, id: \.id) { msg in
                                bubble(for: msg).id(msg.id)
                            }
                        }
                        .padding(24)
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last?.id {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                    .onAppear {
                        if let last = messages.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        } else {
            ContentUnavailableView("Select a conversation",
                                   systemImage: "sidebar.left")
        }
    }

    @ViewBuilder
    private func bubble(for msg: MessageStruct) -> some View {
        // Map embed gets its own bubble — left-aligned, no surrounding card
        // background (the map itself is the surface).
        if let mapAttachment = msg.mapAttachment {
            HStack {
                MapBubble(attachment: mapAttachment)
                    .frame(maxWidth: 420)
                Spacer(minLength: 60)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let fileAttachment = msg.fileAttachment {
            // share_file lands as a function-role message with a
            // FileAttachment; render it as a left-aligned card.
            let isUser = msg.role == "user"
            HStack {
                if isUser { Spacer(minLength: 60) }
                FileAttachmentBubble(attachment: fileAttachment)
                    .frame(maxWidth: 360)
                if !isUser { Spacer(minLength: 60) }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        } else {
            let isUser = msg.role == "user"
            HStack {
                if isUser { Spacer(minLength: 60) }
                VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                    Text(isUser ? "You" : "Loop")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Group {
                        if isUser {
                            Text(msg.content)
                        } else {
                            MarkdownText(markdown: msg.content)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(isUser ? AnyShapeStyle(.tint.opacity(0.25))
                                       : AnyShapeStyle(.thinMaterial),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
                }
                if !isUser { Spacer(minLength: 60) }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }

    /// User/assistant turns of a conversation, newest-readable order, pulled
    /// fresh from the shared store each call. Function-role messages are
    /// kept only when they carry a map or file attachment (where the bubble
    /// itself is the whole point of the message).
    private static func transcript(for id: String) -> [MessageStruct] {
        let mgr = SimpleConversationManager.shared
        guard let conv = mgr.getConversation(by: id) else { return [] }
        return mgr.getMessages(for: conv)
            .map { mgr.messageStruct(from: $0) }
            .filter { msg in
                if msg.mapAttachment != nil { return true }
                if msg.fileAttachment != nil { return true }
                return (msg.role == "user" || msg.role == "assistant") && !msg.content.isEmpty
            }
    }
}

// MARK: - File attachment bubble

/// Minimal SwiftUI card for an attached file — kind badge, name, size, and a
/// tap that hands off to QuickLook (and the system fallback) via an
/// NSItemProvider / share sheet. Lighter than the iOS / Mac equivalents
/// because vision sits in 2D and we don't want a hover-driven snippet —
/// the user opens to inspect.
private struct FileAttachmentBubble: View {
    let attachment: FileAttachment

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(attachment.fileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let snippet = snippetPreview, !snippet.isEmpty {
                        Text(snippet)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .contentShape(Rectangle())
            .onTapGesture { open() }

            if hasTextContent {
                Divider()
                HStack {
                    Spacer()
                    ShareLink(item: shareText) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var iconName: String {
        switch attachment.kind {
        case .markdown: return "doc.text"
        case .text:     return "chevron.left.forwardslash.chevron.right"
        case .pdf:      return "doc.richtext"
        case .image:    return "photo"
        case .generic:  return "doc"
        }
    }

    private var subtitle: String {
        let kindLabel: String
        switch attachment.kind {
        case .markdown: kindLabel = "Markdown"
        case .text:     kindLabel = attachment.languageTag?.capitalized ?? "Text"
        case .pdf:      kindLabel = "PDF"
        case .image:    kindLabel = "Image"
        case .generic:  kindLabel = attachment.mimeType
        }
        if let bytes = (try? attachment.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
            return "\(kindLabel) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
        }
        return kindLabel
    }

    private var snippetPreview: String? {
        switch attachment.kind {
        case .markdown, .text:
            return attachment.extractedText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return nil
        }
    }

    private var hasTextContent: Bool {
        switch attachment.kind {
        case .markdown, .text: return true
        default: return false
        }
    }

    private var shareText: String {
        (try? String(contentsOf: attachment.fileURL, encoding: .utf8)) ?? ""
    }

    private func open() {
        // SwiftUI's openURL handles file:// URLs on visionOS — the system
        // routes them to QuickLook (or a registered handler) without us
        // depending on UIKit directly.
        openURL(attachment.fileURL)
    }
}

// MARK: - Map embed bubble

/// SwiftUI inline map embed. Renders the place set with one Marker per
/// place; tapping a marker opens an info popover with "Open in Maps" that
/// hands the destination to Apple Maps via `MKMapItem.openInMaps`.
private struct MapBubble: View {
    let attachment: MapAttachment

    @State private var selectedPlaceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = attachment.title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Map(initialPosition: initialPosition,
                selection: $selectedPlaceID) {
                ForEach(attachment.places, id: \.markerID) { place in
                    Marker(place.name,
                           coordinate: CLLocationCoordinate2D(
                                latitude: place.latitude,
                                longitude: place.longitude))
                        .tag(place.markerID)
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottom) {
                if let id = selectedPlaceID,
                   let place = attachment.places.first(where: { $0.markerID == id }) {
                    selectionCard(place)
                        .padding(8)
                }
            }
        }
    }

    private var initialPosition: MapCameraPosition {
        // Fit the camera around the bounding box of all places with a small
        // padding factor so pins aren't flush to the edges. Single-place
        // cases fall back to a fixed neighborhood-scale radius.
        let coords = attachment.places.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard !coords.isEmpty else {
            return .automatic
        }
        if coords.count == 1, let only = coords.first {
            return .region(MKCoordinateRegion(
                center: only,
                latitudinalMeters: 1500,
                longitudinalMeters: 1500))
        }
        let lats = coords.map { $0.latitude }
        let lons = coords.map { $0.longitude }
        let minLat = lats.min() ?? 0
        let maxLat = lats.max() ?? 0
        let minLon = lons.min() ?? 0
        let maxLon = lons.max() ?? 0
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.01),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.01))
        return .region(MKCoordinateRegion(center: center, span: span))
    }

    @ViewBuilder
    private func selectionCard(_ place: MapPlace) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let addr = place.address, !addr.isEmpty {
                    Text(addr)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button("Open in Maps") {
                let item = MKMapItem(placemark: MKPlacemark(
                    coordinate: CLLocationCoordinate2D(
                        latitude: place.latitude,
                        longitude: place.longitude)))
                item.name = place.name
                item.openInMaps(launchOptions: [
                    MKLaunchOptionsMapTypeKey: NSNumber(value: MKMapType.standard.rawValue)
                ])
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private extension MapPlace {
    /// Stable identity for `ForEach` / `Map` selection. Lat/lon as a string
    /// is unique enough for the place set since names can collide ("Blue
    /// Bottle Coffee" appears many times in SF).
    var markerID: String { "\(latitude),\(longitude),\(name)" }
}
