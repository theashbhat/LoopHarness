//
//  MessagingCell.swift
//  Loop
//
//  Created by Ash Bhat on 11/3/24.
//

import UIKit
import PhotosUI
import SafariServices
import PDFKit
import QuickLook
import MapKit


/// Tap-callbacks from the inline image bubble. Set on every cell that
/// renders an image attachment so MessagingVC can save / regenerate /
/// open the full-screen viewer.
protocol MessagingCellImageDelegate: AnyObject {
    func messagingCellDidTapDownload(attachmentId: String)
    func messagingCellDidTapRetry(attachmentId: String)
    /// `sourceView` is the tapped attachment image view, handed up so the
    /// full-screen viewer can run a zoom transition out of (and back into)
    /// this exact bubble.
    func messagingCellDidTapImage(attachmentId: String, sourceView: UIView)
}

/// Tap-callbacks from the inline PDF card. Set on every cell that renders
/// a PDF attachment so MessagingVC can present QuickLook / the share
/// sheet / a retry render.
protocol MessagingCellPDFDelegate: AnyObject {
    func messagingCellDidTapPDFPreview(attachmentId: String)
    /// `sourceView` is the tapped share button, handed up so the iPad
    /// activity sheet can anchor its popover here.
    func messagingCellDidTapPDFShare(attachmentId: String, sourceView: UIView)
    func messagingCellDidTapPDFRetry(attachmentId: String)
}

/// Tap-callback from the inline "Used N tools" disclosure row. Set on cells
/// that render an assistant turn carrying tool calls so MessagingVC can toggle
/// the row's expanded/collapsed state.
protocol MessagingCellToolDelegate: AnyObject {
    func messagingCellDidTapToolDisclosure(messageId: String)
}

class MessagingCell: UITableViewCell {
    let profileImageView = UIImageView()
    let textView = UITextView()
    let animatingtextView = UITextView()
    var timer: Timer?

    // MARK: - Type-on reveal animation
    // ChatGPT-style word-by-word fade-in for a freshly arrived assistant
    // message. The base `textView` holds the same text at alpha 0 so the cell
    // reaches its final height on frame one; the fade then plays inside that
    // fixed frame, so it never thrashes tableView layout or jumps scroll —
    // the failure mode that retired the old per-word typewriter.
    /// Drives the fade; nil unless an animation is in flight.
    private var revealLink: CADisplayLink?
    /// Working copy whose per-unit foreground alpha ramps up each frame.
    private var revealString: NSMutableAttributedString?
    /// Reveal units (each a word + its trailing whitespace) over `revealString`.
    private var revealUnits: [NSRange] = []
    /// Original opaque foreground color per unit, so the fade modulates alpha
    /// without clobbering markdown syntax-highlight colors.
    private var revealUnitColors: [UIColor] = []
    /// Units already pinned at full alpha; the moving window only touches
    /// units ahead of this, keeping each frame O(window) not O(length).
    private var revealSettledUnits = 0
    /// Reveal head in "unit" space; advances by `revealUnitsPerSecond`.
    private var revealHead: CGFloat = 0
    private var revealUnitsPerSecond: CGFloat = 0
    private var revealLastTimestamp: CFTimeInterval = 0
    /// Units over which alpha ramps 0→1 — the soft edge that reads as a fade.
    private let revealFadeWindow: CGFloat = 6
    /// Fired once when the reveal reaches the end naturally (not on cancel /
    /// reuse). Used by the onboarding path to reveal its pills afterwards.
    private var revealCompletion: (() -> Void)?

    /// Vertical stack used when the assistant message contains a markdown
    /// table. Holds alternating UITextViews (prose segments) and UIViews
    /// (rendered table grids). Hidden — and emptied — for plain messages
    /// so the existing single-text-view fast path is untouched.
    let richContentStack = UIStackView()
    private var richContentConstraints: [NSLayoutConstraint] = []

    // MARK: - Tool-call disclosure
    /// Vertical container for the collapsible "Used N tools" row. Reused across
    /// cells; its arranged subviews are rebuilt per `applyToolDisclosure` pass.
    let toolDisclosureStack = UIStackView()
    private var toolDisclosureConstraints: [NSLayoutConstraint] = []
    /// Message id of the turn currently rendered as a disclosure — handed to
    /// `toolDelegate` when the header is tapped.
    private var toolDisclosureMessageId: String?
    /// Set by MessagingVC before `setData` for a tool-call turn. Controls
    /// whether the per-call body rows are shown.
    var toolExpanded: Bool = false
    /// Resolves a call into its display title (humanized name) + subtitle
    /// (argument summary). Injected by MessagingVC so the cell reuses the VC's
    /// skill-aware `statusText` humanization instead of duplicating it.
    var toolDisplayProvider: ((FunctionCallStruct) -> (title: String, subtitle: String))?
    weak var toolDelegate: MessagingCellToolDelegate?

    let actionButton = UIButton()

    let shimmerLabel = ShimmerLabel()
    let modelLabel = UILabel()
    /// Spinner shown next to `modelLabel` while TTS is generating audio. Set
    /// via `setTTSStatus(_:)`. Hidden by default so user/system messages stay
    /// untouched.
    let ttsIndicator = UIActivityIndicatorView(style: .medium)

    // MARK: - Swipe-to-reveal timestamp (iMessage-style)
    /// Sits just off the cell's right edge; revealed when the chat is swiped
    /// left. MessagingVC drives every visible cell's `contentView` translation
    /// in lock-step from a single pan, so all bubbles slide together and these
    /// labels come into view at once. Text is the message's posted time.
    let timeLabel: UILabel = {
        let l = UILabel()
        l.font = .preferredFont(forTextStyle: .caption1)
        l.textColor = .secondaryLabel
        l.textAlignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()
    private var timeLabelInstalled = false
    /// Formats a message's `timestamp` for the swipe-reveal label. Shows the
    /// short time for today's messages and a "M/d, h:mm a" stamp for older ones,
    /// mirroring how iMessage labels its swiped timestamps.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd jmm")
        return f
    }()

    // MARK: - Inline image attachment views (image_spec)
    let attachmentImageView = UIImageView()
    let attachmentSpinner = UIActivityIndicatorView(style: .large)
    let attachmentErrorLabel = UILabel()
    let downloadButton = UIButton(type: .system)
    let retryButton = UIButton(type: .system)
    weak var imageDelegate: MessagingCellImageDelegate?

    // MARK: - Inline PDF attachment views (pdf_spec)
    /// Container for the PDF card. Lazily added so plain messages don't
    /// allocate the entire PDF widget tree they'd never display.
    private lazy var pdfCardView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.layer.cornerRadius = 14
        v.layer.borderWidth = 1
        v.layer.borderColor = UIColor.systemFill.cgColor
        v.backgroundColor = UIColor.secondarySystemBackground
        v.isHidden = true
        return v
    }()
    private lazy var pdfThumbnailView: UIImageView = {
        let v = UIImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.contentMode = .scaleAspectFit
        v.clipsToBounds = true
        v.layer.cornerRadius = 6
        v.layer.borderWidth = 0.5
        v.layer.borderColor = UIColor.separator.cgColor
        v.backgroundColor = .white
        v.isUserInteractionEnabled = true
        return v
    }()
    private lazy var pdfTitleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = UIFont.preferredFont(forTextStyle: .headline)
        l.textColor = .label
        l.numberOfLines = 2
        return l
    }()
    private lazy var pdfSubtitleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = UIFont.preferredFont(forTextStyle: .footnote)
        l.textColor = .secondaryLabel
        l.numberOfLines = 1
        return l
    }()
    private lazy var pdfSpinner: UIActivityIndicatorView = {
        let s = UIActivityIndicatorView(style: .medium)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.hidesWhenStopped = true
        return s
    }()
    private lazy var pdfErrorLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = UIFont.preferredFont(forTextStyle: .footnote)
        l.textColor = .secondaryLabel
        l.numberOfLines = 0
        return l
    }()
    private lazy var pdfPreviewButton: UIButton = {
        let b = makePDFActionButton(title: "Preview",
                                    systemImage: "eye",
                                    action: #selector(handlePDFPreviewTap))
        return b
    }()
    private lazy var pdfShareButton: UIButton = {
        let b = makePDFActionButton(title: "Share",
                                    systemImage: "square.and.arrow.up",
                                    action: #selector(handlePDFShareTap))
        return b
    }()
    private lazy var pdfRetryButton: UIButton = {
        let b = makePDFActionButton(title: "Try again",
                                    systemImage: "arrow.clockwise",
                                    action: #selector(handlePDFRetryTap))
        return b
    }()
    private lazy var pdfThumbnailTapRecognizer: UITapGestureRecognizer = {
        let r = UITapGestureRecognizer(target: self, action: #selector(handlePDFPreviewTap))
        r.numberOfTapsRequired = 1
        return r
    }()
    private var pdfCardConstraints: [NSLayoutConstraint] = []
    private var currentPDFAttachmentId: String?
    weak var pdfDelegate: MessagingCellPDFDelegate?

    // MARK: - Inline map attachment views (MapsSkill)
    /// Caption label shown above the map (optional — hidden when nil).
    private lazy var mapTitleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        l.textColor = .label
        l.numberOfLines = 2
        l.isHidden = true
        return l
    }()
    /// MKMapView with one pin per place. Tappable callouts deep-link into
    /// Apple Maps. Lazy so plain messages don't pay for the map runtime.
    private lazy var mapView: MKMapView = {
        let m = MKMapView()
        m.translatesAutoresizingMaskIntoConstraints = false
        m.layer.cornerRadius = 14
        m.layer.borderWidth = 1
        m.layer.borderColor = UIColor.systemFill.cgColor
        m.clipsToBounds = true
        m.isHidden = true
        m.delegate = self
        m.showsCompass = false
        m.showsScale = false
        m.isPitchEnabled = false
        m.isRotateEnabled = false
        m.register(MKMarkerAnnotationView.self,
                   forAnnotationViewWithReuseIdentifier: MessagingCell.mapPinReuseId)
        return m
    }()
    private static let mapPinReuseId = "MessagingCellMapPin"
    private var mapConstraints: [NSLayoutConstraint] = []
    private var currentMapAttachmentId: String?

    private var currentAttachmentId: String?
    /// Set by `applyFileAttachment` (user upload) so the tap handler can
    /// open a QuickLook preview directly instead of routing through the
    /// AI-generated image viewer delegate.
    private var currentAttachmentFileURL: URL?
    /// Set alongside `currentAttachmentFileURL` so the file-preview card's
    /// tap handler can route markdown → in-app editor while text / generic /
    /// pdf continue to fall through to QuickLook.
    private var currentAttachmentKind: FileAttachment.Kind?
    private var attachmentConstraints: [NSLayoutConstraint] = []

    /// Preview card used for non-image/PDF attachments (markdown, source
    /// code, plain text, generic catch-all). Lazily added so plain messages
    /// don't pay for a view they'll never display.
    private lazy var filePreviewCard: FilePreviewCardView = {
        let v = FilePreviewCardView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        v.onTap = { [weak self] in self?.handleFilePreviewCardTap() }
        return v
    }()
    private var filePreviewCardConstraints: [NSLayoutConstraint] = []

    /// Card view used when this message carries an onboarding card. Lazy so
    /// the regular message-cell layout pays no cost when the card isn't in
    /// play. The cell only hosts it — the rendering logic lives in
    /// `OnboardingCardView` so this file stays focused on its existing
    /// text / image / file paths.
    private lazy var onboardingCardView: OnboardingCardView = {
        let v = OnboardingCardView()
        v.isHidden = true
        return v
    }()
    private var onboardingCardConstraints: [NSLayoutConstraint] = []
    /// Forwarded to `onboardingCardView.delegate` on every apply. Set by
    /// MessagingVC via the cell's `onboardingDelegate` property in
    /// `cellForRowAt`, the same pattern as `imageDelegate`.
    weak var onboardingDelegate: OnboardingCardDelegate?
    /// Lazy single-instance tap recognizer so the cell can re-gate it via
    /// isEnabled across reuse instead of stacking new gestures each pass.
    private lazy var imageTapRecognizer: UITapGestureRecognizer = {
        let r = UITapGestureRecognizer(target: self, action: #selector(handleImageTap))
        r.numberOfTapsRequired = 1
        return r
    }()

    /// The "raw" model name (e.g. "GPT 5.5 Instant") last applied via
    /// `setData`. Kept around so `setTTSStatus(_:)` can append the
    /// "| 2.03s to audio" suffix without losing the base text on cell reuse.
    private var baseModelText: String?

    // Store constraints to avoid conflicts during cell reuse
    private var textViewConstraints: [NSLayoutConstraint] = []
    private var animatingTextViewConstraints: [NSLayoutConstraint] = []
    private var profileImageViewConstraints: [NSLayoutConstraint] = []
    private var shimmerLabelConstraints: [NSLayoutConstraint] = []
    private var modelLabelConstraints: [NSLayoutConstraint] = []
    
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        self.setup()
    }
    
    func setup() {
        self.selectionStyle = .none

        // Enable link interaction. The text views are not editable but must be
        // selectable for iOS to deliver tap events to attributed-string links.
        textView.isSelectable = true
        textView.isEditable = false
        textView.delegate = self
        animatingtextView.isSelectable = true
        animatingtextView.isEditable = false
        animatingtextView.delegate = self

        richContentStack.translatesAutoresizingMaskIntoConstraints = false
        richContentStack.axis = .vertical
        richContentStack.alignment = .fill
        richContentStack.distribution = .fill
        richContentStack.spacing = 8
        richContentStack.isHidden = true

        toolDisclosureStack.translatesAutoresizingMaskIntoConstraints = false
        toolDisclosureStack.axis = .vertical
        toolDisclosureStack.alignment = .leading
        toolDisclosureStack.spacing = 6
        toolDisclosureStack.isHidden = true
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()

        // Invalidate any running timer
        timer?.invalidate()
        timer = nil

        // Reset the swipe-to-reveal slide so a recycled cell doesn't carry over
        // a mid-swipe offset, and clear the stale time text.
        contentView.transform = .identity
        timeLabel.text = nil

        // Halt any in-flight type-on reveal so a recycled cell doesn't keep
        // fading into the wrong message.
        stopTypeOnReveal()

        // Hide all views instead of removing them for better performance
        profileImageView.isHidden = true
        textView.isHidden = true
        animatingtextView.isHidden = true
        actionButton.isHidden = true
        shimmerLabel.isHidden = true
        modelLabel.isHidden = true
        modelLabel.text = nil
        ttsIndicator.stopAnimating()
        ttsIndicator.isHidden = true
        baseModelText = nil

        // Image attachment cleanup — stop spinner, drop the bitmap so a
        // recycled cell doesn't briefly flash a stale image.
        attachmentSpinner.stopAnimating()
        attachmentSpinner.isHidden = true
        attachmentImageView.image = nil
        attachmentImageView.isHidden = true
        attachmentErrorLabel.isHidden = true
        attachmentErrorLabel.text = nil
        downloadButton.isHidden = true
        retryButton.isHidden = true
        currentAttachmentId = nil
        currentAttachmentFileURL = nil
        currentAttachmentKind = nil
        NSLayoutConstraint.deactivate(attachmentConstraints)
        attachmentConstraints.removeAll()

        // File-preview card cleanup. Hide rather than remove so a recycled
        // cell that renders another card next pass keeps the same view.
        filePreviewCard.isHidden = true
        filePreviewCard.reset()
        NSLayoutConstraint.deactivate(filePreviewCardConstraints)
        filePreviewCardConstraints.removeAll()

        // PDF card cleanup. Hide + clear so a recycled cell that next
        // renders a plain message doesn't flash a stale thumbnail or title.
        pdfCardView.isHidden = true
        pdfThumbnailView.image = nil
        pdfTitleLabel.text = nil
        pdfSubtitleLabel.text = nil
        pdfErrorLabel.text = nil
        pdfErrorLabel.isHidden = true
        pdfSpinner.stopAnimating()
        pdfSpinner.isHidden = true
        pdfPreviewButton.isHidden = true
        pdfShareButton.isHidden = true
        pdfRetryButton.isHidden = true
        currentPDFAttachmentId = nil
        NSLayoutConstraint.deactivate(pdfCardConstraints)
        pdfCardConstraints.removeAll()

        // Map cleanup — drop annotations so a recycled cell doesn't briefly
        // show the previous message's pins.
        mapView.removeAnnotations(mapView.annotations)
        mapView.isHidden = true
        mapTitleLabel.isHidden = true
        mapTitleLabel.text = nil
        currentMapAttachmentId = nil
        NSLayoutConstraint.deactivate(mapConstraints)
        mapConstraints.removeAll()

        // Onboarding-card cleanup. Same hide-and-reset pattern as the file
        // preview card — the view is reused across cells that render
        // different card kinds.
        onboardingCardView.isHidden = true
        // Restore full opacity / position — a cell recycled mid type-on
        // reveal would otherwise carry over the alpha-0 + offset the pill
        // fade-in started from.
        onboardingCardView.alpha = 1
        onboardingCardView.transform = .identity
        onboardingCardView.reset()
        NSLayoutConstraint.deactivate(onboardingCardConstraints)
        onboardingCardConstraints.removeAll()
        onboardingDelegate = nil
        
        // Reset view states
        textView.alpha = 1.0
        animatingtextView.alpha = 1.0
        textView.attributedText = nil
        animatingtextView.attributedText = nil
        textView.text = nil
        animatingtextView.text = nil
        
        // Reset text view properties
        textView.textContainerInset = .zero
        textView.layer.cornerRadius = 0
        textView.layer.borderWidth = 0
        textView.layer.borderColor = UIColor.clear.cgColor

        // Tear down rich-content (table) views so the next message starts
        // from a clean slate. The stack itself is reused.
        NSLayoutConstraint.deactivate(richContentConstraints)
        richContentConstraints.removeAll()
        richContentStack.arrangedSubviews.forEach {
            richContentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        richContentStack.isHidden = true

        // Tool-disclosure cleanup — hide, drop subviews/constraints, and clear
        // the injected state so a recycled cell doesn't carry over a stale
        // delegate, expanded flag, or display provider.
        toolDisclosureStack.isHidden = true
        NSLayoutConstraint.deactivate(toolDisclosureConstraints)
        toolDisclosureConstraints.removeAll()
        toolDisclosureStack.arrangedSubviews.forEach {
            toolDisclosureStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        toolDisclosureMessageId = nil
        toolExpanded = false
        toolDisplayProvider = nil
        toolDelegate = nil
    }

    private func clearAllConstraints() {
        // Deactivate all stored constraints
        NSLayoutConstraint.deactivate(textViewConstraints)
        NSLayoutConstraint.deactivate(animatingTextViewConstraints)
        NSLayoutConstraint.deactivate(profileImageViewConstraints)
        NSLayoutConstraint.deactivate(shimmerLabelConstraints)
        NSLayoutConstraint.deactivate(modelLabelConstraints)

        // Clear the arrays
        textViewConstraints.removeAll()
        animatingTextViewConstraints.removeAll()
        profileImageViewConstraints.removeAll()
        shimmerLabelConstraints.removeAll()
        modelLabelConstraints.removeAll()
    }
    
    func setAnimationState(state: AIState) {
        // Clear existing constraints
        clearAllConstraints()

        // Ensure all views are added to content view (only once)
        if profileImageView.superview == nil {
            self.addViews(views: [profileImageView, textView, animatingtextView, actionButton, shimmerLabel, modelLabel, ttsIndicator])
        }

        // Show animation views, hide others. Profile image is gone for the
        // assistant — the nav-bar AvatarView is the new single visual anchor
        // for "the AI is here," so cells just left-align their copy.
        profileImageView.isHidden = true
        textView.isHidden = true
        animatingtextView.isHidden = true
        actionButton.isHidden = true
        shimmerLabel.isHidden = false
        modelLabel.isHidden = true

        shimmerLabelConstraints = [
            shimmerLabel.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 20),
            shimmerLabel.trailingAnchor.constraint(lessThanOrEqualTo: self.contentView.trailingAnchor, constant: -20),
            shimmerLabel.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 20),
            self.contentView.bottomAnchor.constraint(greaterThanOrEqualTo: shimmerLabel.bottomAnchor, constant: 20),
        ]

        NSLayoutConstraint.activate(shimmerLabelConstraints)

        shimmerLabel.font = UIFont.preferredFont(forTextStyle: .body)
        shimmerLabel.text = state.displayText
        shimmerLabel.shimmerColor = .tertiarySystemBackground
        shimmerLabel.textColor = .label
        shimmerLabel.numberOfLines = 0
        shimmerLabel.lineBreakMode = .byWordWrapping

        
    }
    
    func setData(data: MessageStruct, shouldAnimate: Bool) {
        // Clear existing constraints
        clearAllConstraints()

        // Ensure all views are added to content view (only once)
        if profileImageView.superview == nil {
            self.addViews(views: [profileImageView, textView, animatingtextView, actionButton, shimmerLabel, modelLabel, ttsIndicator])
        }
        if attachmentImageView.superview == nil {
            self.addViews(views: [attachmentImageView, attachmentSpinner, attachmentErrorLabel, downloadButton, retryButton])
        }

        // Swipe-left reveals when this message was posted. Set on every render
        // path (early-returns below all inherit it), so all bubble kinds slide
        // out to the same timestamp column.
        setTimeLabel(for: data.timestamp)

        // Onboarding card takes its own dedicated path: a left-aligned text
        // bubble with the prompt and an interactive card pinned underneath.
        // Routed first so it bypasses the image / file / table branches
        // below — onboarding messages never carry those.
        if let card = data.onboardingCard, data.role == "assistant" {
            applyOnboardingCard(card, accompanyingText: data.content, shouldAnimate: shouldAnimate)
            return
        }
        // User-side onboarding echoes (the .done sentinel) render as plain
        // right-aligned bubbles, so we fall through to the normal user-text
        // branch below.

        // Inline image attachment (image_spec) takes a separate code path so
        // we don't need to interleave it with text-bubble layout.
        if let attachment = data.imageAttachment {
            applyImageAttachment(attachment, modelLabelText: modelText(for: data))
            return
        }

        // Inline PDF attachment (pdf_spec). Renders as a card with the
        // page-1 thumbnail + title + page count + Preview/Share buttons.
        if let pdfAttachment = data.pdfAttachment {
            applyPDFAttachment(pdfAttachment, modelLabelText: modelText(for: data))
            return
        }

        // Inline map embed — MKMapView with one pin per place. Callouts
        // open Apple Maps for that destination.
        if let mapAttachment = data.mapAttachment {
            applyMapAttachment(mapAttachment, modelLabelText: modelText(for: data))
            return
        }

        // File attachment. Renders on the user side (right-aligned) for
        // uploads, the assistant side for share_file results. The function-
        // role variant carries an LLM-only confirmation string in `content`
        // ("Shared X with the user…") — that's not for the human reader, so
        // suppress it and let the card stand alone.
        if let fileAttachment = data.fileAttachment {
            let accompanyingText = data.role == "function" ? "" : data.content
            applyFileAttachment(fileAttachment, accompanyingText: accompanyingText, role: data.role)
            return
        }

        // Assistant turn carrying tool calls — render the collapsible
        // "Used N tools" disclosure instead of an (often empty) text bubble.
        // Routed before the plain-text branch since these turns usually have
        // no human-facing prose of their own.
        if data.role == "assistant" && !data.functions.isEmpty {
            applyToolDisclosure(data: data)
            return
        }

        if data.role == "assistant" {
            // Markdown-table fast branch: when the response contains a GFM
            // table, lay it out as a real UIStackView grid instead of
            // routing through the single-text-view + animation path.
            // Streaming animation is skipped here because table responses
            // are typically already complete by the time they render.
            if MarkdownSegmenter.containsRichContent(in: data.content) {
                applyRichContent(data: data)
                return
            }

            // Show assistant views, hide user views. The profile image is
            // gone — the nav-bar AvatarView covers the visual identity, so
            // assistant text just left-aligns to the cell edge.
            profileImageView.isHidden = true
            textView.isHidden = false
            animatingtextView.isHidden = false
            actionButton.isHidden = true
            shimmerLabel.isHidden = true
            modelLabel.isHidden = false

            // Text view: left-aligned, leaves room on the right for any
            // trailing UI to grow without crowding.
            textViewConstraints = [
                textView.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 20),
                textView.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 12),
                textView.widthAnchor.constraint(lessThanOrEqualTo: self.contentView.widthAnchor, multiplier: 1.0, constant: -40)
            ]

            animatingTextViewConstraints = [
                animatingtextView.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 0),
                animatingtextView.topAnchor.constraint(equalTo: textView.topAnchor, constant: 0),
                animatingtextView.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: 0),
                animatingtextView.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: 0)
            ]

            // Model label sits below the message bubble; drives the cell's bottom.
            // The TTS indicator pins to the trailing edge of modelLabel and is
            // hidden until setTTSStatus(_:) flips it on.
            modelLabelConstraints = [
                modelLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
                modelLabel.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 4),
                self.contentView.bottomAnchor.constraint(greaterThanOrEqualTo: modelLabel.bottomAnchor, constant: 10),
                ttsIndicator.leadingAnchor.constraint(equalTo: modelLabel.trailingAnchor, constant: 6),
                ttsIndicator.centerYAnchor.constraint(equalTo: modelLabel.centerYAnchor),
                ttsIndicator.widthAnchor.constraint(equalToConstant: 12),
                ttsIndicator.heightAnchor.constraint(equalToConstant: 12),
                ttsIndicator.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor)
            ]

            NSLayoutConstraint.activate(textViewConstraints)
            NSLayoutConstraint.activate(animatingTextViewConstraints)
            NSLayoutConstraint.activate(modelLabelConstraints)

            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
            textView.isScrollEnabled = false
            textView.isEditable = false
            textView.textContainer.maximumNumberOfLines = 0
            textView.textContainer.widthTracksTextView = true
            
            animatingtextView.textContainerInset = .zero
            animatingtextView.textContainer.lineFragmentPadding = 0
            animatingtextView.isScrollEnabled = false
            animatingtextView.isEditable = false
            animatingtextView.textContainer.maximumNumberOfLines = 0
            animatingtextView.textContainer.widthTracksTextView = true
            
            
            textView.attributedText = self.attributedString(from: data.content)
            textView.textColor = .label
            textView.font = UIFont.preferredFont(forTextStyle: .body)
            textView.alpha = 0.1
            textView.layer.borderWidth = 0
            textView.layer.borderColor = UIColor.clear.cgColor
            
            animatingtextView.alpha = 1
            animatingtextView.textColor = .label
//            animatingtextView.text = data.content
            animatingtextView.font = UIFont.preferredFont(forTextStyle: .body)

            let byline = modelText(for: data)
            baseModelText = byline
            modelLabel.text = byline
            modelLabel.textColor = .secondaryLabel
            modelLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
            modelLabel.numberOfLines = 1
            ttsIndicator.color = .secondaryLabel
            ttsIndicator.hidesWhenStopped = true
            ttsIndicator.stopAnimating()
            ttsIndicator.isHidden = true

            // Type-on: fade the words in left-to-right for a freshly arrived
            // response (shouldAnimate). On cell reuse / scroll-back
            // (shouldAnimate == false) or with Reduce Motion on, render
            // instantly. Unlike the old per-word typewriter (`animateText`) —
            // which re-ran markdown regex per tick and relaid out the table —
            // this renders markdown once, fixes the height via `textView`, and
            // only modulates per-word alpha. See docs/streaming-investigation.md.
            let full = self.attributedString(from: data.content)
            if shouldAnimate, !UIAccessibility.isReduceMotionEnabled {
                startTypeOnReveal(full: full)
            } else {
                stopTypeOnReveal()
                textView.alpha = 1.0
                animatingtextView.alpha = 1
                animatingtextView.attributedText = full
            }
            
            // Update content size after setting text
            // updateContentSize() // Disabled for better scroll performance
        }
        else {
            // Show user views, hide assistant views
            profileImageView.isHidden = true
            textView.isHidden = false
            animatingtextView.isHidden = true
            actionButton.isHidden = true
            shimmerLabel.isHidden = true
            modelLabel.isHidden = true
            
            // Store and activate text view constraints for user messages
            textViewConstraints = [
                textView.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -10),
                textView.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 6),
                textView.widthAnchor.constraint(lessThanOrEqualTo: self.contentView.widthAnchor, multiplier: 0.8, constant: -40),
                textView.bottomAnchor.constraint(equalTo: self.contentView.bottomAnchor, constant: -6)
            ]
            
            NSLayoutConstraint.activate(textViewConstraints)
            animatingtextView.alpha = 0
            textView.alpha = 1
            textView.textContainerInset = .init(top: 8, left: 10, bottom: 8, right: 10)
            textView.textContainer.lineFragmentPadding = 0
            textView.textContainer.maximumNumberOfLines = 0
            textView.textContainer.widthTracksTextView = true
            textView.layer.cornerRadius = 10
            textView.layer.borderWidth = 2
            textView.layer.borderColor = UIColor.systemFill.cgColor
            textView.font = UIFont.preferredFont(forTextStyle: .body)
            textView.isScrollEnabled = false
            textView.isEditable = false
            textView.attributedText = self.attributedString(from: data.content)
            animatingtextView.isEditable = false
            
            // Update content size after setting text
            // updateContentSize() // Disabled for better scroll performance
        }
    }

    /// TTS audio-generation status applied on top of `modelLabel`. The cell
    /// is reused, so callers should reapply this every time the cell becomes
    /// visible (typically from `cellForRowAt`).
    enum TTSStatus {
        /// Audio request is in flight. Spinner shown next to the model name.
        case generating
        /// Audio finished generating. Appends "| 2.03s to audio" to the label.
        case ready(seconds: TimeInterval)
        /// No TTS happening for this message — restore the bare model name.
        case none
    }

    func setTTSStatus(_ status: TTSStatus) {
        let base = baseModelText ?? modelLabel.text ?? ""
        switch status {
        case .none:
            modelLabel.text = base
            ttsIndicator.stopAnimating()
            ttsIndicator.isHidden = true
        case .generating:
            modelLabel.text = base
            ttsIndicator.isHidden = false
            ttsIndicator.startAnimating()
        case .ready(let seconds):
            let formatted = String(format: "%.2fs", seconds)
            modelLabel.text = base.isEmpty ? "\(formatted) to audio"
                                          : "\(base) | \(formatted) to audio"
            ttsIndicator.stopAnimating()
            ttsIndicator.isHidden = true
        }
    }


    
    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority, verticalFittingPriority: UILayoutPriority) -> CGSize {
        // Force layout to get accurate size
        self.contentView.setNeedsLayout()
        self.contentView.layoutIfNeeded()
        
        // Calculate the size based on content
        let size = self.contentView.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontalFittingPriority, verticalFittingPriority: verticalFittingPriority)
        
        // Only apply minimum height for assistant cells (those with profile image)
        // Check if profileImageView is in the view hierarchy
        let hasProfileImage = profileImageView.superview != nil
        
        if hasProfileImage {
            // Use the calculated size - don't force a minimum height that creates extra padding
            // The contentView's profileImageView constraint already ensures proper spacing
            return size
        } else {
            // For user cells, use a smaller minimum height for more compact single-line messages
            let minimumHeight: CGFloat = 40
            return CGSize(width: size.width, height: max(size.height, minimumHeight))
        }
    }
    
    func addViews(views: [UIView]) {
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            self.contentView.addSubview(view)
        }
    }

    // MARK: - Swipe-to-reveal timestamp

    /// Adds `timeLabel` to the content view exactly once, pinned just past the
    /// right edge so it's off-screen until the chat is swiped left. It rides
    /// inside `contentView`, so translating the content view (see
    /// `setTimeRevealOffset`) slides the bubble out and this label in together —
    /// the whole row moves as one unit, like iMessage.
    private func installTimeLabelIfNeeded() {
        guard !timeLabelInstalled else { return }
        timeLabelInstalled = true
        // Content view must not clip, or the off-edge label is invisible even
        // once revealed.
        contentView.clipsToBounds = false
        contentView.addSubview(timeLabel)
        // Trailing is pinned past the right edge by (reveal column − inset), so
        // at a full swipe the label settles 12pt from the edge, right-aligned —
        // wider "older message" stamps grow leftward instead of clipping. Must
        // stay in sync with MessagingVC.timeRevealMax.
        NSLayoutConstraint.activate([
            timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: 72 - 12),
            timeLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    /// Sets the swipe-reveal time text for this row from its message.
    func setTimeLabel(for date: Date) {
        installTimeLabelIfNeeded()
        timeLabel.text = Calendar.current.isDateInToday(date)
            ? Self.timeFormatter.string(from: date)
            : Self.dayTimeFormatter.string(from: date)
    }

    /// Slides the whole row left by `offset` points to reveal the timestamp.
    /// Driven by MessagingVC's pan so every visible cell moves in lock-step.
    func setTimeRevealOffset(_ offset: CGFloat) {
        contentView.transform = offset == 0
            ? .identity
            : CGAffineTransform(translationX: -offset, y: 0)
    }
    
    func attributedString(from text: String) -> NSAttributedString {
        // Delegated to the shared helper so the chat bubble and the
        // expanded AgentView transcript share a single source of truth for
        // markdown styling.
        return MarkdownAttributedString.render(text)
    }

    // MARK: - Type-on reveal

    /// Begin a ChatGPT-style word-by-word fade-in of `full` in
    /// `animatingtextView`. The base `textView` holds the same text at alpha 0
    /// so the cell reaches its final height up front and the fade plays inside
    /// a fixed frame (no relayout / scroll jump).
    private func startTypeOnReveal(full: NSAttributedString, onComplete: (() -> Void)? = nil) {
        stopTypeOnReveal()
        revealCompletion = onComplete

        // Invisible base layer fixes the final layout/height.
        textView.attributedText = full
        textView.alpha = 0

        let units = wordUnits(in: full.string as NSString)
        // Empty or single word — nothing meaningful to animate.
        guard units.count > 1 else {
            animatingtextView.alpha = 1
            animatingtextView.attributedText = full
            textView.alpha = 1
            let done = revealCompletion
            revealCompletion = nil
            done?()
            return
        }

        // Snapshot each unit's real color, then knock every unit to alpha 0.
        let working = NSMutableAttributedString(attributedString: full)
        var colors: [UIColor] = []
        colors.reserveCapacity(units.count)
        for unit in units {
            let base = (full.attribute(.foregroundColor, at: unit.location, effectiveRange: nil) as? UIColor) ?? .label
            colors.append(base)
            working.addAttribute(.foregroundColor, value: base.withAlphaComponent(0), range: unit)
        }

        revealString = working
        revealUnits = units
        revealUnitColors = colors
        revealSettledUnits = 0
        revealHead = 0
        revealLastTimestamp = 0

        // Bound total time so short replies aren't instant and long ones don't
        // crawl: ~12ms/word, clamped to [0.35s, 1.4s]. The head must also
        // traverse the trailing fade window, hence the `+ revealFadeWindow`.
        let duration = min(max(Double(units.count) * 0.012, 0.35), 1.4)
        revealUnitsPerSecond = (CGFloat(units.count) + revealFadeWindow) / CGFloat(duration)

        animatingtextView.alpha = 1
        animatingtextView.attributedText = working

        let link = CADisplayLink(target: self, selector: #selector(stepTypeOnReveal(_:)))
        link.add(to: .main, forMode: .common)
        revealLink = link
    }

    @objc private func stepTypeOnReveal(_ link: CADisplayLink) {
        guard let working = revealString, !revealUnits.isEmpty else {
            stopTypeOnReveal()
            return
        }

        if revealLastTimestamp == 0 { revealLastTimestamp = link.timestamp }
        revealHead += revealUnitsPerSecond * CGFloat(link.timestamp - revealLastTimestamp)
        revealLastTimestamp = link.timestamp

        let count = revealUnits.count
        let trailing = revealHead - revealFadeWindow

        // Pin units fully behind the window at their real color, once each.
        let settleTarget = trailing >= 0 ? min(count, Int(trailing.rounded(.down)) + 1) : 0
        if settleTarget > revealSettledUnits {
            for i in revealSettledUnits..<settleTarget {
                working.addAttribute(.foregroundColor, value: revealUnitColors[i], range: revealUnits[i])
            }
            revealSettledUnits = settleTarget
        }

        // Ramp alpha across units currently inside the fade window.
        let activeEnd = revealHead >= 0 ? min(count, Int(revealHead.rounded(.down)) + 1) : 0
        if revealSettledUnits < activeEnd {
            for i in revealSettledUnits..<activeEnd {
                let alpha = min(max((revealHead - CGFloat(i)) / revealFadeWindow, 0), 1)
                working.addAttribute(.foregroundColor,
                                     value: revealUnitColors[i].withAlphaComponent(alpha),
                                     range: revealUnits[i])
            }
        }

        animatingtextView.attributedText = working

        if revealSettledUnits >= count {
            // Grab the completion before teardown clears it, then fire after —
            // this is the only path that runs it (cancel / reuse never do).
            let done = revealCompletion
            stopTypeOnReveal()
            done?()
        }
    }

    /// Tear down the reveal and free its working state. Idempotent. Does NOT
    /// fire `revealCompletion` — only natural completion in step does.
    private func stopTypeOnReveal() {
        revealLink?.invalidate()
        revealLink = nil
        revealString = nil
        revealUnits = []
        revealUnitColors = []
        revealSettledUnits = 0
        revealHead = 0
        revealLastTimestamp = 0
        revealCompletion = nil
    }

    /// Split `string` into reveal units: each a run of non-whitespace plus the
    /// whitespace that trails it (so spaces/newlines ride along and we never
    /// reveal a dangling gap). Leading whitespace forms its own unit.
    private func wordUnits(in string: NSString) -> [NSRange] {
        // Common BMP whitespace code units: space, tab, LF, CR, VT, FF, NBSP.
        let ws: Set<unichar> = [0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C, 0xA0]
        var units: [NSRange] = []
        let len = string.length
        var i = 0
        while i < len {
            let start = i
            while i < len, !ws.contains(string.character(at: i)) { i += 1 }
            while i < len, ws.contains(string.character(at: i)) { i += 1 }
            units.append(NSRange(location: start, length: i - start))
        }
        return units
    }

    /// Build the model-label base text, appending "| Context X%" when token
    /// usage data and a known context window size are both available.
    private func modelText(for data: MessageStruct) -> String {
        var text = data.model
        // Time-to-first-token, right after the model name: "GPT-5.5 2.6s".
        if let ttft = data.ttft {
            text += String(format: " %.2fs", ttft)
        }
        if let usage = data.tokenUsage,
           let window = ModelSelection.contextWindowSize(forStamp: data.model),
           let pct = usage.contextPercent(windowSize: window) {
            text += " | Context \(pct)%"
        }
        return text
    }


    // MARK: - Rich content (markdown tables)

    /// Build the assistant bubble as a vertical stack of prose UITextViews
    /// and grid UIViews when the response contains a GFM table. Mirrors
    /// the layout of the plain-text branch (left-aligned, model label
    /// underneath) but swaps the single text view for `richContentStack`.
    private func applyRichContent(data: MessageStruct) {
        profileImageView.isHidden = true
        textView.isHidden = true
        animatingtextView.isHidden = true
        actionButton.isHidden = true
        shimmerLabel.isHidden = true
        modelLabel.isHidden = false

        // Idempotent re-entry: drop any rich state from a prior setData
        // call so we never stack duplicate constraints / subviews if the
        // cell is reconfigured without a prepareForReuse pass in between.
        NSLayoutConstraint.deactivate(richContentConstraints)
        richContentConstraints.removeAll()
        richContentStack.arrangedSubviews.forEach {
            richContentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if richContentStack.superview == nil {
            richContentStack.translatesAutoresizingMaskIntoConstraints = false
            self.contentView.addSubview(richContentStack)
        }
        richContentStack.isHidden = false

        // Populate the stack with one subview per parsed segment.
        for segment in MarkdownSegmenter.segments(from: data.content) {
            switch segment {
            case .text(let prose):
                let tv = makeProseTextView(text: prose)
                richContentStack.addArrangedSubview(tv)
            case .table(let table):
                let view = makeTableView(table: table)
                richContentStack.addArrangedSubview(view)
            case .codeBlock(let block):
                let view = makeCodeBlockView(block: block)
                richContentStack.addArrangedSubview(view)
            }
        }

        // Pin the rich stack to the full available content width (not
        // lessThanOrEqual): without an enforced width the UIStackView
        // shrinks to its arranged-subviews' intrinsic widths, which
        // squishes a grid of short cells like ("ash", "founder") down to
        // an unreadable thumbnail. Tables need to occupy the bubble.
        richContentConstraints = [
            richContentStack.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 20),
            richContentStack.trailingAnchor.constraint(equalTo: self.contentView.trailingAnchor, constant: -20),
            richContentStack.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 12),
        ]
        NSLayoutConstraint.activate(richContentConstraints)

        // Model label / TTS indicator hang off the bottom of the rich stack
        // instead of the now-hidden text view.
        modelLabelConstraints = [
            modelLabel.leadingAnchor.constraint(equalTo: richContentStack.leadingAnchor),
            modelLabel.topAnchor.constraint(equalTo: richContentStack.bottomAnchor, constant: 4),
            self.contentView.bottomAnchor.constraint(greaterThanOrEqualTo: modelLabel.bottomAnchor, constant: 10),
            ttsIndicator.leadingAnchor.constraint(equalTo: modelLabel.trailingAnchor, constant: 6),
            ttsIndicator.centerYAnchor.constraint(equalTo: modelLabel.centerYAnchor),
            ttsIndicator.widthAnchor.constraint(equalToConstant: 12),
            ttsIndicator.heightAnchor.constraint(equalToConstant: 12),
            ttsIndicator.trailingAnchor.constraint(lessThanOrEqualTo: richContentStack.trailingAnchor),
        ]
        NSLayoutConstraint.activate(modelLabelConstraints)

        let byline = modelText(for: data)
        baseModelText = byline
        modelLabel.text = byline
        modelLabel.textColor = .secondaryLabel
        modelLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
        modelLabel.numberOfLines = 1
        ttsIndicator.color = .secondaryLabel
        ttsIndicator.hidesWhenStopped = true
        ttsIndicator.stopAnimating()
        ttsIndicator.isHidden = true
    }

    /// Renders an assistant tool-call turn as a compact, tappable
    /// "Used N tools" row that expands to list each call's humanized name and
    /// a short argument summary. Mirrors `applyRichContent`'s self-contained
    /// setup (own constraints, rebuilt subviews) so it's safe on cell reuse.
    private func applyToolDisclosure(data: MessageStruct) {
        profileImageView.isHidden = true
        textView.isHidden = true
        animatingtextView.isHidden = true
        actionButton.isHidden = true
        shimmerLabel.isHidden = true
        modelLabel.isHidden = true

        // Idempotent re-entry — drop any prior disclosure subviews/constraints
        // so a reconfigured cell never stacks duplicates.
        NSLayoutConstraint.deactivate(toolDisclosureConstraints)
        toolDisclosureConstraints.removeAll()
        toolDisclosureStack.arrangedSubviews.forEach {
            toolDisclosureStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if toolDisclosureStack.superview == nil {
            toolDisclosureStack.translatesAutoresizingMaskIntoConstraints = false
            self.contentView.addSubview(toolDisclosureStack)
        }
        toolDisclosureStack.isHidden = false
        toolDisclosureMessageId = data.id

        // Width-capped views (prose + body rows) get their bubble-width
        // constraint activated below, after they're in the hierarchy.
        var widthBoundedRows: [UIView] = []

        // Pre-tool assistant prose, if any, sits above the disclosure.
        let trimmed = data.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let prose = makeProseTextView(text: data.content)
            toolDisclosureStack.addArrangedSubview(prose)
            widthBoundedRows.append(prose)
        }

        let calls = data.functions

        // Header: chevron + "Used N tool(s)". Tappable to toggle expansion.
        toolDisclosureStack.addArrangedSubview(
            makeToolDisclosureHeader(count: calls.count, expanded: toolExpanded))

        // Body: one row per call, shown only when expanded. Each row's width is
        // bounded to the bubble so a long argument summary wraps/truncates — but
        // those constraints reference `contentView` and so must be activated
        // only after the row is in the hierarchy (below), not at creation time.
        if toolExpanded {
            for call in calls {
                let display = toolDisplayProvider?(call) ?? (title: call.name, subtitle: "")
                let row = makeToolCallRow(title: display.title, subtitle: display.subtitle)
                toolDisclosureStack.addArrangedSubview(row)
                widthBoundedRows.append(row)
            }
        }

        toolDisclosureConstraints = [
            toolDisclosureStack.leadingAnchor.constraint(equalTo: self.contentView.leadingAnchor, constant: 20),
            toolDisclosureStack.trailingAnchor.constraint(lessThanOrEqualTo: self.contentView.trailingAnchor, constant: -20),
            toolDisclosureStack.topAnchor.constraint(equalTo: self.contentView.topAnchor, constant: 12),
            self.contentView.bottomAnchor.constraint(greaterThanOrEqualTo: toolDisclosureStack.bottomAnchor, constant: 10),
        ]
        // Now that the rows are arranged subviews of the in-hierarchy stack,
        // they share an ancestor with contentView, so the width caps are legal.
        for row in widthBoundedRows {
            toolDisclosureConstraints.append(
                row.widthAnchor.constraint(lessThanOrEqualTo: self.contentView.widthAnchor, multiplier: 1.0, constant: -40))
        }
        NSLayoutConstraint.activate(toolDisclosureConstraints)
    }

    /// The tappable header pill: a chevron that points right (collapsed) or
    /// down (expanded) next to "Used N tool(s)". Sized to its content so it
    /// reads as a subtle control rather than a full-width bar.
    private func makeToolDisclosureHeader(count: Int, expanded: Bool) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .secondarySystemBackground
        container.layer.cornerRadius = 12
        container.isUserInteractionEnabled = true

        let chevron = UIImageView(image: UIImage(systemName: expanded ? "chevron.down" : "chevron.right"))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .scaleAspectFit

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Used \(count) tool\(count == 1 ? "" : "s")"
        label.font = UIFont.preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel

        container.addSubview(chevron)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            chevron.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.heightAnchor.constraint(equalToConstant: 10),
            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -7),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleToolDisclosureTap))
        container.addGestureRecognizer(tap)
        return container
    }

    /// One expanded body row: the humanized tool name (label color) followed
    /// by its argument summary (secondary color), truncated to two lines.
    private func makeToolCallRow(title: String, subtitle: String) -> UIView {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail

        let text = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .footnote),
                .foregroundColor: UIColor.label,
            ])
        if !subtitle.isEmpty {
            text.append(NSAttributedString(
                string: "  \(subtitle)",
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .footnote),
                    .foregroundColor: UIColor.secondaryLabel,
                ]))
        }
        label.attributedText = text

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        // Only internal (same-hierarchy) constraints here. The bubble-width cap
        // is added by the caller once this row is in the view tree — referencing
        // contentView before insertion crashes ("no common ancestor").
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])
        return container
    }

    @objc private func handleToolDisclosureTap() {
        guard let id = toolDisclosureMessageId else { return }
        toolDelegate?.messagingCellDidTapToolDisclosure(messageId: id)
    }

    /// A non-scrolling UITextView styled like the existing prose bubble.
    /// Re-uses `attributedString(from:)` so bold/italic/links/paths render
    /// identically to plain messages.
    private func makeProseTextView(text: String) -> UITextView {
        let tv = UITextView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.isScrollEnabled = false
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.delegate = self
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.textColor = .label
        tv.attributedText = attributedString(from: text)
        return tv
    }

    /// Builds a rounded container with monospaced code text, a subtle
    /// background, and an optional language label in the top-right corner.
    private func makeCodeBlockView(block: MarkdownCodeBlock) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor.label.withAlphaComponent(0.06)
        container.layer.cornerRadius = 8
        container.layer.cornerCurve = .continuous
        container.layer.masksToBounds = true

        let codeTV = UITextView()
        codeTV.translatesAutoresizingMaskIntoConstraints = false
        codeTV.isScrollEnabled = false
        codeTV.isEditable = false
        codeTV.isSelectable = true
        codeTV.backgroundColor = .clear
        codeTV.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        codeTV.textContainer.lineFragmentPadding = 0
        let codeFont = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize - 1, weight: .regular)
        codeTV.attributedText = CodeSyntaxHighlighter.highlight(
            block.code, language: block.language, font: codeFont)
        container.addSubview(codeTV)

        NSLayoutConstraint.activate([
            codeTV.topAnchor.constraint(equalTo: container.topAnchor),
            codeTV.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            codeTV.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            codeTV.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        if let lang = block.language, !lang.isEmpty {
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.text = lang
            label.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            label.textColor = .secondaryLabel
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            ])
        }

        return container
    }

    /// Build a UIStackView grid for `table`. Rows are full-width with
    /// equal-width columns; header is bold on a tinted background; body
    /// rows alternate fill for readability. Borders and dividers use
    /// `.separator` so dark mode looks right out of the box.
    private func makeTableView(table: MarkdownTable) -> UIView {
        // AdaptiveBorderView re-resolves layer.borderColor on appearance
        // changes — UIView.backgroundColor handles that itself for dynamic
        // UIColors, but CGColors on CALayer don't, and the border would
        // otherwise stay frozen at whatever mode was active when the
        // table was first built.
        let container = AdaptiveBorderView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = 8
        container.adaptiveBorderColor = UIColor.separator
        container.layer.borderWidth = 0.5
        container.layer.masksToBounds = true
        container.backgroundColor = UIColor.secondarySystemBackground

        let vstack = UIStackView()
        vstack.translatesAutoresizingMaskIntoConstraints = false
        vstack.axis = .vertical
        vstack.alignment = .fill
        vstack.distribution = .fill
        vstack.spacing = 0
        container.addSubview(vstack)
        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: container.topAnchor),
            vstack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            vstack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vstack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        vstack.addArrangedSubview(
            makeTableRow(cells: table.headers,
                         alignments: table.alignments,
                         isHeader: true,
                         altBackground: false))

        for (i, row) in table.rows.enumerated() {
            vstack.addArrangedSubview(makeHairlineDivider())
            vstack.addArrangedSubview(
                makeTableRow(cells: row,
                             alignments: table.alignments,
                             isHeader: false,
                             altBackground: i.isMultiple(of: 2) == false))
        }

        return container
    }

    private func makeHairlineDivider() -> UIView {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = UIColor.separator
        v.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return v
    }

    private func makeTableRow(cells: [String],
                              alignments: [MarkdownColumnAlignment],
                              isHeader: Bool,
                              altBackground: Bool) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        if isHeader {
            row.backgroundColor = UIColor.tertiarySystemBackground
        } else if altBackground {
            row.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.5)
        } else {
            row.backgroundColor = .clear
        }

        let hstack = UIStackView()
        hstack.translatesAutoresizingMaskIntoConstraints = false
        hstack.axis = .horizontal
        hstack.alignment = .fill
        hstack.distribution = .fillEqually
        hstack.spacing = 0
        row.addSubview(hstack)
        NSLayoutConstraint.activate([
            hstack.topAnchor.constraint(equalTo: row.topAnchor),
            hstack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            hstack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            hstack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])

        // Column dividers go *inside* each non-leading cell rather than
        // as arranged subviews of `hstack`. `.fillEqually` requires every
        // arranged subview to share width — a 0.5pt divider sitting in
        // the line-up either gets stretched (breaking the divider) or
        // wins its own width (breaking equal-column sizing), producing
        // the squished-column layout we hit before.
        for (i, cellText) in cells.enumerated() {
            let alignment = i < alignments.count ? alignments[i] : .left
            let cellView = makeTableCell(text: cellText,
                                          alignment: alignment,
                                          isHeader: isHeader,
                                          leadingDivider: i > 0)
            hstack.addArrangedSubview(cellView)
        }

        return row
    }

    private func makeTableCell(text: String,
                                alignment: MarkdownColumnAlignment,
                                isHeader: Bool,
                                leadingDivider: Bool) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        // Let `.fillEqually` win the width sizing battle. UILabel hugs
        // its content by default, which can fight an equal-width row
        // when one cell's text is much shorter than the rest.
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let base = UIFont.preferredFont(forTextStyle: .subheadline)
        label.font = isHeader
            ? UIFont.systemFont(ofSize: base.pointSize, weight: .semibold)
            : base
        label.textColor = .label
        // Inline marks (bold/italic/links) inside cells reuse the same
        // renderer the surrounding prose uses, so styling stays consistent.
        // UILabel ignores `textAlignment` when `attributedText` is set, so
        // the alignment is folded into the attributed string via a
        // paragraph style applied over the full range.
        let attributed = NSMutableAttributedString(attributedString: attributedString(from: text))
        let paragraph = NSMutableParagraphStyle()
        switch alignment {
        case .left:   paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right:  paragraph.alignment = .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        attributed.addAttribute(.paragraphStyle,
                                value: paragraph,
                                range: NSRange(location: 0, length: attributed.length))
        label.attributedText = attributed

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
        ])

        if leadingDivider {
            let line = UIView()
            line.translatesAutoresizingMaskIntoConstraints = false
            line.backgroundColor = UIColor.separator
            container.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                line.topAnchor.constraint(equalTo: container.topAnchor),
                line.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                line.widthAnchor.constraint(equalToConstant: 0.5),
            ])
        }

        return container
    }

    // MARK: - Inline image attachment rendering (image_spec)

    /// Lay out an inline-image bubble on the assistant's avatar row. Three
    /// visual states drive button visibility + center content:
    /// - .generating: spinner over a placeholder rect, no buttons
    /// - .ready:      image filled, download + retry buttons below
    /// - .failed:     error label centered, retry button below
    private func applyImageAttachment(_ attachment: ImageAttachment,
                                       modelLabelText: String) {
        currentAttachmentId = attachment.id

        // Profile image is gone — the bubble left-aligns to the cell edge,
        // matching the text branch above.
        profileImageView.isHidden = true
        textView.isHidden = true
        animatingtextView.isHidden = true
        actionButton.isHidden = true
        shimmerLabel.isHidden = true
        modelLabel.isHidden = false

        attachmentImageView.isHidden = false
        attachmentImageView.translatesAutoresizingMaskIntoConstraints = false
        attachmentImageView.contentMode = .scaleAspectFill
        attachmentImageView.clipsToBounds = true
        attachmentImageView.layer.cornerRadius = 14
        attachmentImageView.layer.borderWidth = 1
        attachmentImageView.layer.borderColor = UIColor.systemFill.cgColor
        attachmentImageView.backgroundColor = UIColor.secondarySystemBackground

        // Tap-to-zoom: install once (lazy gesture is idempotent per instance,
        // and addGestureRecognizer is a no-op if already attached). Gating on
        // .ready avoids opening a viewer for an empty placeholder or error
        // bubble where there's nothing to show.
        attachmentImageView.isUserInteractionEnabled = (attachment.status == .ready)
        if imageTapRecognizer.view !== attachmentImageView {
            attachmentImageView.addGestureRecognizer(imageTapRecognizer)
        }
        imageTapRecognizer.isEnabled = (attachment.status == .ready)

        attachmentSpinner.translatesAutoresizingMaskIntoConstraints = false
        attachmentSpinner.color = .secondaryLabel
        attachmentSpinner.hidesWhenStopped = true

        attachmentErrorLabel.translatesAutoresizingMaskIntoConstraints = false
        attachmentErrorLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        attachmentErrorLabel.textColor = .secondaryLabel
        attachmentErrorLabel.numberOfLines = 0
        attachmentErrorLabel.textAlignment = .center

        // Configure buttons (idempotent — safe to re-run on cell reuse).
        configureRoundButton(downloadButton,
                             systemImage: "arrow.down.circle",
                             accessibility: "Save to Photos",
                             action: #selector(handleDownloadTap))
        configureRoundButton(retryButton,
                             systemImage: "arrow.clockwise.circle",
                             accessibility: "Generate again",
                             action: #selector(handleRetryTap))

        // Image bubble: fixed 240×240 inline. Compact enough that two iterations
        // fit on screen; large enough to see the result without tapping in.
        let imageSide: CGFloat = 240
        attachmentConstraints = [
            attachmentImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            attachmentImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            attachmentImageView.widthAnchor.constraint(equalToConstant: imageSide),
            attachmentImageView.heightAnchor.constraint(equalToConstant: imageSide),

            attachmentSpinner.centerXAnchor.constraint(equalTo: attachmentImageView.centerXAnchor),
            attachmentSpinner.centerYAnchor.constraint(equalTo: attachmentImageView.centerYAnchor),

            attachmentErrorLabel.leadingAnchor.constraint(equalTo: attachmentImageView.leadingAnchor, constant: 12),
            attachmentErrorLabel.trailingAnchor.constraint(equalTo: attachmentImageView.trailingAnchor, constant: -12),
            attachmentErrorLabel.centerYAnchor.constraint(equalTo: attachmentImageView.centerYAnchor),

            downloadButton.leadingAnchor.constraint(equalTo: attachmentImageView.leadingAnchor),
            downloadButton.topAnchor.constraint(equalTo: attachmentImageView.bottomAnchor, constant: 8),
            downloadButton.widthAnchor.constraint(equalToConstant: 32),
            downloadButton.heightAnchor.constraint(equalToConstant: 32),

            retryButton.leadingAnchor.constraint(equalTo: downloadButton.trailingAnchor, constant: 8),
            retryButton.centerYAnchor.constraint(equalTo: downloadButton.centerYAnchor),
            retryButton.widthAnchor.constraint(equalToConstant: 32),
            retryButton.heightAnchor.constraint(equalToConstant: 32),

            modelLabel.leadingAnchor.constraint(equalTo: attachmentImageView.leadingAnchor),
            modelLabel.topAnchor.constraint(equalTo: downloadButton.bottomAnchor, constant: 6),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: modelLabel.bottomAnchor, constant: 12),
        ]
        NSLayoutConstraint.activate(attachmentConstraints)

        // State-specific UI.
        switch attachment.status {
        case .generating:
            attachmentImageView.image = nil
            attachmentSpinner.isHidden = false
            attachmentSpinner.startAnimating()
            attachmentErrorLabel.isHidden = true
            downloadButton.isHidden = true
            retryButton.isHidden = true
        case .ready:
            attachmentSpinner.stopAnimating()
            attachmentSpinner.isHidden = true
            attachmentErrorLabel.isHidden = true
            if let url = attachment.fileURL,
               let data = try? Data(contentsOf: url),
               let image = UIImage(data: data) {
                attachmentImageView.image = image
            }
            downloadButton.isHidden = false
            retryButton.isHidden = false
        case .failed:
            attachmentImageView.image = nil
            attachmentSpinner.stopAnimating()
            attachmentSpinner.isHidden = true
            attachmentErrorLabel.isHidden = false
            attachmentErrorLabel.text = attachment.failureReason ?? "Image generation failed."
            downloadButton.isHidden = true
            retryButton.isHidden = false
        }

        // Model label — same caption styling as the text-bubble branch so
        // the user can tell which model produced the image.
        baseModelText = modelLabelText
        modelLabel.text = modelLabelText
        modelLabel.textColor = .secondaryLabel
        modelLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
        modelLabel.numberOfLines = 1
        ttsIndicator.stopAnimating()
        ttsIndicator.isHidden = true
    }

    // MARK: - Inline PDF attachment rendering

    /// Lay out the PDF card on the assistant side. Three visual states:
    /// - .generating: spinner over a thumbnail placeholder, "Generating PDF…"
    /// - .ready:      thumbnail + title + page count + Preview/Share buttons
    /// - .failed:     thumbnail slot shows generic icon, error label + Try again
    private func applyPDFAttachment(_ attachment: PDFAttachment,
                                    modelLabelText: String) {
        currentPDFAttachmentId = attachment.id

        // Hide every other render path's views; PDF takes over the row.
        profileImageView.isHidden = true
        textView.isHidden = true
        animatingtextView.isHidden = true
        actionButton.isHidden = true
        shimmerLabel.isHidden = true
        modelLabel.isHidden = false
        attachmentImageView.isHidden = true
        attachmentSpinner.stopAnimating()
        attachmentSpinner.isHidden = true
        attachmentErrorLabel.isHidden = true
        downloadButton.isHidden = true
        retryButton.isHidden = true

        if pdfCardView.superview == nil {
            self.contentView.addSubview(pdfCardView)
            pdfCardView.addSubview(pdfThumbnailView)
            pdfCardView.addSubview(pdfTitleLabel)
            pdfCardView.addSubview(pdfSubtitleLabel)
            pdfCardView.addSubview(pdfSpinner)
            pdfCardView.addSubview(pdfErrorLabel)
            pdfCardView.addSubview(pdfPreviewButton)
            pdfCardView.addSubview(pdfShareButton)
            pdfCardView.addSubview(pdfRetryButton)
        }
        if pdfThumbnailTapRecognizer.view !== pdfThumbnailView {
            pdfThumbnailView.addGestureRecognizer(pdfThumbnailTapRecognizer)
        }

        pdfCardView.isHidden = false

        // Card sized to ~88% of the cell width so it doesn't crowd the
        // edges. Thumbnail is fixed; text + buttons fill the rest.
        let thumbWidth: CGFloat = 80
        let thumbHeight: CGFloat = 104   // Letter aspect (8.5×11) at width=80

        pdfCardConstraints = [
            pdfCardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            pdfCardView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            pdfCardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),

            pdfThumbnailView.leadingAnchor.constraint(equalTo: pdfCardView.leadingAnchor, constant: 12),
            pdfThumbnailView.topAnchor.constraint(equalTo: pdfCardView.topAnchor, constant: 12),
            pdfThumbnailView.widthAnchor.constraint(equalToConstant: thumbWidth),
            pdfThumbnailView.heightAnchor.constraint(equalToConstant: thumbHeight),

            pdfTitleLabel.leadingAnchor.constraint(equalTo: pdfThumbnailView.trailingAnchor, constant: 12),
            pdfTitleLabel.trailingAnchor.constraint(equalTo: pdfCardView.trailingAnchor, constant: -12),
            pdfTitleLabel.topAnchor.constraint(equalTo: pdfThumbnailView.topAnchor, constant: 2),

            pdfSubtitleLabel.leadingAnchor.constraint(equalTo: pdfTitleLabel.leadingAnchor),
            pdfSubtitleLabel.trailingAnchor.constraint(equalTo: pdfTitleLabel.trailingAnchor),
            pdfSubtitleLabel.topAnchor.constraint(equalTo: pdfTitleLabel.bottomAnchor, constant: 4),

            pdfSpinner.centerXAnchor.constraint(equalTo: pdfThumbnailView.centerXAnchor),
            pdfSpinner.centerYAnchor.constraint(equalTo: pdfThumbnailView.centerYAnchor),

            pdfErrorLabel.leadingAnchor.constraint(equalTo: pdfTitleLabel.leadingAnchor),
            pdfErrorLabel.trailingAnchor.constraint(equalTo: pdfTitleLabel.trailingAnchor),
            pdfErrorLabel.topAnchor.constraint(equalTo: pdfSubtitleLabel.bottomAnchor, constant: 4),

            pdfPreviewButton.leadingAnchor.constraint(equalTo: pdfThumbnailView.trailingAnchor, constant: 12),
            pdfPreviewButton.topAnchor.constraint(greaterThanOrEqualTo: pdfErrorLabel.bottomAnchor, constant: 8),
            pdfPreviewButton.topAnchor.constraint(greaterThanOrEqualTo: pdfSubtitleLabel.bottomAnchor, constant: 8),
            pdfPreviewButton.bottomAnchor.constraint(equalTo: pdfCardView.bottomAnchor, constant: -12),

            pdfShareButton.leadingAnchor.constraint(equalTo: pdfPreviewButton.trailingAnchor, constant: 8),
            pdfShareButton.centerYAnchor.constraint(equalTo: pdfPreviewButton.centerYAnchor),

            pdfRetryButton.leadingAnchor.constraint(equalTo: pdfPreviewButton.trailingAnchor, constant: 8),
            pdfRetryButton.centerYAnchor.constraint(equalTo: pdfPreviewButton.centerYAnchor),

            pdfCardView.bottomAnchor.constraint(greaterThanOrEqualTo: pdfThumbnailView.bottomAnchor, constant: 12),

            modelLabel.leadingAnchor.constraint(equalTo: pdfCardView.leadingAnchor),
            modelLabel.topAnchor.constraint(equalTo: pdfCardView.bottomAnchor, constant: 6),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: modelLabel.bottomAnchor, constant: 12),
        ]
        NSLayoutConstraint.activate(pdfCardConstraints)

        pdfTitleLabel.text = attachment.title

        switch attachment.status {
        case .generating:
            pdfThumbnailView.image = nil
            pdfThumbnailView.backgroundColor = UIColor.tertiarySystemBackground
            pdfSpinner.isHidden = false
            pdfSpinner.startAnimating()
            pdfSubtitleLabel.text = "Generating PDF…"
            pdfErrorLabel.isHidden = true
            pdfPreviewButton.isHidden = true
            pdfShareButton.isHidden = true
            pdfRetryButton.isHidden = true
            pdfThumbnailTapRecognizer.isEnabled = false
        case .ready:
            pdfSpinner.stopAnimating()
            pdfSpinner.isHidden = true
            pdfThumbnailView.backgroundColor = .white
            if let url = attachment.thumbnailURL,
               let data = try? Data(contentsOf: url),
               let image = UIImage(data: data) {
                pdfThumbnailView.image = image
            } else {
                // Thumbnail render failed but PDF is fine — show a generic
                // doc icon so the cell still reads as a file.
                pdfThumbnailView.image = UIImage(systemName: "doc.richtext")
                pdfThumbnailView.tintColor = .secondaryLabel
            }
            let pages = attachment.pageCount ?? 0
            let pageWord = pages == 1 ? "page" : "pages"
            let templateLabel = attachment.template.capitalized
            pdfSubtitleLabel.text = pages > 0
                ? "\(pages) \(pageWord) · \(templateLabel)"
                : templateLabel
            pdfErrorLabel.isHidden = true
            pdfPreviewButton.isHidden = false
            pdfShareButton.isHidden = false
            pdfRetryButton.isHidden = true
            pdfThumbnailTapRecognizer.isEnabled = true
        case .failed:
            pdfSpinner.stopAnimating()
            pdfSpinner.isHidden = true
            pdfThumbnailView.image = UIImage(systemName: "doc.badge.ellipsis")
            pdfThumbnailView.tintColor = .systemRed
            pdfThumbnailView.backgroundColor = UIColor.tertiarySystemBackground
            pdfSubtitleLabel.text = "Couldn't generate PDF"
            pdfErrorLabel.isHidden = false
            pdfErrorLabel.text = attachment.failureReason
            pdfPreviewButton.isHidden = true
            pdfShareButton.isHidden = true
            pdfRetryButton.isHidden = false
            pdfThumbnailTapRecognizer.isEnabled = false
        }

        baseModelText = modelLabelText
        modelLabel.text = modelLabelText
        modelLabel.textColor = .secondaryLabel
        modelLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
        modelLabel.numberOfLines = 1
        ttsIndicator.stopAnimating()
        ttsIndicator.isHidden = true
    }

    private func makePDFActionButton(title: String,
                                     systemImage: String,
                                     action: Selector) -> UIButton {
        // Explicit `contentInsets` + footnote-sized title because the default
        // `.small` button size applies tight system insets that fight
        // `imagePadding` — the leading icon ends up outside the tinted
        // background. Driving padding and font directly keeps the icon +
        // title fully inside the pill on every size class.
        var cfg = UIButton.Configuration.tinted()
        cfg.title = title
        cfg.image = UIImage(systemName: systemImage)
        cfg.imagePadding = 6
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 14)
        cfg.cornerStyle = .medium
        cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = UIFont.preferredFont(forTextStyle: .footnote)
            return out
        }
        let imageConfig = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .medium)
        cfg.preferredSymbolConfigurationForImage = imageConfig
        let b = UIButton(configuration: cfg)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addTarget(self, action: action, for: .touchUpInside)
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        return b
    }

    @objc private func handlePDFPreviewTap() {
        guard let id = currentPDFAttachmentId else { return }
        pdfDelegate?.messagingCellDidTapPDFPreview(attachmentId: id)
    }

    @objc private func handlePDFShareTap() {
        guard let id = currentPDFAttachmentId else { return }
        pdfDelegate?.messagingCellDidTapPDFShare(attachmentId: id, sourceView: pdfShareButton)
    }

    @objc private func handlePDFRetryTap() {
        guard let id = currentPDFAttachmentId else { return }
        pdfDelegate?.messagingCellDidTapPDFRetry(attachmentId: id)
    }

    private func configureRoundButton(_ button: UIButton,
                                      systemImage: String,
                                      accessibility: String,
                                      action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        button.setImage(UIImage(systemName: systemImage, withConfiguration: cfg), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = accessibility
        button.removeTarget(nil, action: nil, for: .allEvents)
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    @objc private func handleDownloadTap() {
        guard let id = currentAttachmentId else { return }
        imageDelegate?.messagingCellDidTapDownload(attachmentId: id)
    }

    @objc private func handleRetryTap() {
        guard let id = currentAttachmentId else { return }
        imageDelegate?.messagingCellDidTapRetry(attachmentId: id)
    }

    @objc private func handleImageTap() {
        // User-uploaded attachment (image or PDF): QuickLook the file
        // directly. AI-generated images route through the existing delegate
        // so MessagingVC can present its own zoom viewer.
        if let url = currentAttachmentFileURL {
            presentQuickLook(for: url)
            return
        }
        guard let id = currentAttachmentId else { return }
        imageDelegate?.messagingCellDidTapImage(attachmentId: id, sourceView: attachmentImageView)
    }

    private func presentQuickLook(for url: URL) {
        guard let presenter = parentViewController else { return }
        let preview = QLPreviewController()
        let source = MessagingCellQLSource(url: url)
        preview.dataSource = source
        // Hold the source on the preview so it survives the present animation
        // — QLPreviewController only weakly references its data source.
        objc_setAssociatedObject(preview, &MessagingCellQLSource.assocKey, source,
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        presenter.present(preview, animated: true)
    }

    // MARK: - User-uploaded file attachment rendering

    /// Renders a user-attached file as a right-aligned bubble. Images/PDFs
    /// get an inline thumbnail (QuickLook on tap); markdown/source/generic
    /// route through `applyFilePreviewCardAttachment` which renders an icon +
    /// filename + snippet card. Accompanying text (if any) is shown as a
    /// caption underneath either path.
    /// Render an onboarding card under the assistant prompt text. The bubble
    /// uses the same left-aligned text layout as a normal assistant message,
    /// but the model label is hidden (onboarding turns have no model
    /// attribution). For `.answered`, render just the prose — the chip
    /// row collapses away and the cell shrinks to the height of the bubble.
    private func applyOnboardingCard(_ kind: OnboardingCardKind, accompanyingText: String, shouldAnimate: Bool) {
        if onboardingCardView.superview == nil {
            contentView.addSubview(onboardingCardView)
            onboardingCardView.translatesAutoresizingMaskIntoConstraints = false
        }
        let hasInteractiveCard = (kind != .answered)
        onboardingCardView.isHidden = !hasInteractiveCard
        onboardingCardView.apply(kind, delegate: onboardingDelegate)

        // Type the prose on for any freshly-arrived prompt with text —
        // including the terminal `.done` sign-off, which has no pills. The
        // pill reveal is gated separately on `hasInteractiveCard` below.
        // Reuse / scroll-back and Reduce Motion render instantly.
        let animate = shouldAnimate && !accompanyingText.isEmpty
            && !UIAccessibility.isReduceMotionEnabled

        // Visible chrome: just the prompt text and (maybe) the card. Hide
        // everything else that could bleed in via cell reuse.
        profileImageView.isHidden = true
        textView.isHidden = false
        animatingtextView.isHidden = !animate
        actionButton.isHidden = true
        shimmerLabel.isHidden = true
        modelLabel.isHidden = true
        attachmentImageView.isHidden = true
        attachmentSpinner.isHidden = true
        attachmentErrorLabel.isHidden = true
        downloadButton.isHidden = true
        retryButton.isHidden = true

        // Configure the textView baseline FIRST. Assigning `font` or
        // `textColor` on a UITextView clobbers per-range attributes in
        // attributedText (Apple's documented behavior), so the attributed
        // string assignment has to come last — otherwise the bold ranges
        // produced by `attributedString(from:)` get flattened back to
        // regular weight and the user sees plain text with literal
        // asterisks gone but no bold.
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.isEditable = false
        animatingtextView.backgroundColor = .clear
        animatingtextView.textContainerInset = .zero
        animatingtextView.textContainer.lineFragmentPadding = 0
        animatingtextView.isScrollEnabled = false
        animatingtextView.isEditable = false
        // Prompt text runs through the same markdown formatter the regular
        // assistant path uses so onboarding can bold key phrases / use inline
        // links to guide the user.
        let full = self.attributedString(from: accompanyingText)
        textView.attributedText = full

        textViewConstraints = [
            textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            textView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            textView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            textView.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ]

        // animatingtextView overlays textView exactly so the fade lands on top
        // of the (alpha-0) base layer that fixes the cell's final height.
        animatingTextViewConstraints = [
            animatingtextView.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            animatingtextView.topAnchor.constraint(equalTo: textView.topAnchor),
            animatingtextView.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            animatingtextView.bottomAnchor.constraint(equalTo: textView.bottomAnchor),
        ]

        // Bottom anchor depends on whether the card is visible. When the
        // user has already answered, drive the cell bottom off the text so
        // the row collapses to just the prose.
        if hasInteractiveCard {
            onboardingCardConstraints = [
                onboardingCardView.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
                onboardingCardView.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 10),
                onboardingCardView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
                onboardingCardView.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
                contentView.bottomAnchor.constraint(equalTo: onboardingCardView.bottomAnchor, constant: 14),
            ]
        } else {
            onboardingCardConstraints = [
                contentView.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: 12),
            ]
        }
        NSLayoutConstraint.activate(textViewConstraints)
        NSLayoutConstraint.activate(onboardingCardConstraints)

        if animate {
            // The card's slot is already reserved by the constraints above, so
            // typing the prose out and then fading the pills in causes no
            // layout shift. Type on the base (alpha-0) textView, then reveal
            // the pills on completion.
            NSLayoutConstraint.activate(animatingTextViewConstraints)
            // Hold the pills hidden + nudged down until the prose finishes,
            // then rise them into place. Skipped when there's no interactive
            // card (e.g. the terminal `.done` sign-off): the text still types
            // on, there's just nothing to reveal afterwards. The transform is
            // a transform, not a constraint change, so the reserved slot's
            // height is untouched and nothing reflows.
            if hasInteractiveCard {
                onboardingCardView.alpha = 0
                onboardingCardView.transform = CGAffineTransform(translationX: 0, y: 8)
            }
            startTypeOnReveal(full: full) { [weak self] in
                guard let self = self, hasInteractiveCard else { return }
                UIView.animate(withDuration: 0.3,
                               delay: 0,
                               usingSpringWithDamping: 0.82,
                               initialSpringVelocity: 0,
                               options: [.curveEaseOut]) {
                    self.onboardingCardView.alpha = 1
                    self.onboardingCardView.transform = .identity
                }
            }
        } else {
            // Instant render: full prose, pills already visible.
            stopTypeOnReveal()
            textView.alpha = 1
            animatingtextView.alpha = 0
            onboardingCardView.alpha = 1
            onboardingCardView.transform = .identity
        }
    }

    fileprivate func applyFileAttachment(_ attachment: FileAttachment,
                                         accompanyingText: String,
                                         role: String) {
        currentAttachmentKind = attachment.kind
        if attachment.kind != .image && attachment.kind != .pdf {
            applyFilePreviewCardAttachment(attachment,
                                           accompanyingText: accompanyingText,
                                           role: role)
            return
        }
        currentAttachmentId = attachment.id
        currentAttachmentFileURL = attachment.fileURL

        profileImageView.isHidden = true
        animatingtextView.isHidden = true
        actionButton.isHidden = true
        shimmerLabel.isHidden = true
        modelLabel.isHidden = true
        attachmentErrorLabel.isHidden = true
        downloadButton.isHidden = true
        retryButton.isHidden = true
        attachmentSpinner.stopAnimating()
        attachmentSpinner.isHidden = true

        // Accompanying user text below the file bubble (e.g. "what is this?")
        // — only shown if the message actually has copy. We piggyback on
        // `textView` since the cell already configures it for plain text.
        let hasText = !accompanyingText.isEmpty
        textView.isHidden = !hasText

        attachmentImageView.isHidden = false
        attachmentImageView.translatesAutoresizingMaskIntoConstraints = false
        attachmentImageView.contentMode = .scaleAspectFill
        attachmentImageView.clipsToBounds = true
        attachmentImageView.layer.cornerRadius = 14
        attachmentImageView.layer.borderWidth = 1
        attachmentImageView.layer.borderColor = UIColor.systemFill.cgColor
        attachmentImageView.backgroundColor = UIColor.secondarySystemBackground

        attachmentImageView.isUserInteractionEnabled = true
        if imageTapRecognizer.view !== attachmentImageView {
            attachmentImageView.addGestureRecognizer(imageTapRecognizer)
        }
        imageTapRecognizer.isEnabled = true

        // Size differs by kind — square for images, shorter for PDFs.
        let imageSide: CGFloat = 240
        let pdfHeight: CGFloat = 140

        // Pin to the user edge for user uploads, the assistant edge for
        // share_file results — matches the card branch above.
        let isUserSide = (role == "user")
        var constraints: [NSLayoutConstraint] = [
            attachmentImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            attachmentImageView.widthAnchor.constraint(equalToConstant: imageSide),
        ]
        if isUserSide {
            constraints.append(
                attachmentImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10)
            )
        } else {
            constraints.append(
                attachmentImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20)
            )
        }
        constraints.append(
            attachmentImageView.heightAnchor.constraint(equalToConstant: attachment.kind == .pdf ? pdfHeight : imageSide)
        )

        if hasText {
            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.textContainerInset = .init(top: 8, left: 10, bottom: 8, right: 10)
            textView.textContainer.lineFragmentPadding = 0
            textView.textContainer.maximumNumberOfLines = 0
            textView.textContainer.widthTracksTextView = true
            textView.layer.cornerRadius = 10
            textView.layer.borderWidth = isUserSide ? 2 : 0
            textView.layer.borderColor = UIColor.systemFill.cgColor
            textView.font = UIFont.preferredFont(forTextStyle: .body)
            textView.alpha = 1
            textView.isScrollEnabled = false
            textView.isEditable = false
            textView.attributedText = self.attributedString(from: accompanyingText)

            constraints += [
                textView.topAnchor.constraint(equalTo: attachmentImageView.bottomAnchor, constant: 6),
                textView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.8, constant: -40),
                textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            ]
            if isUserSide {
                constraints.append(
                    textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10)
                )
            } else {
                constraints.append(
                    textView.leadingAnchor.constraint(equalTo: attachmentImageView.leadingAnchor)
                )
            }
        } else {
            constraints.append(
                contentView.bottomAnchor.constraint(greaterThanOrEqualTo: attachmentImageView.bottomAnchor, constant: 12)
            )
        }

        attachmentConstraints = constraints
        NSLayoutConstraint.activate(constraints)

        // Render the preview off the main thread. PDFs become a thumbnail of
        // page 1; images get loaded directly. Either way `currentAttachmentId`
        // is the gate against stale callbacks on a recycled cell.
        let id = attachment.id
        let url = attachment.fileURL
        let kind = attachment.kind
        let pdfSize = CGSize(width: imageSide, height: pdfHeight)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image: UIImage?
            switch kind {
            case .image:
                image = (try? Data(contentsOf: url)).flatMap(UIImage.init(data:))
            case .pdf:
                image = MessagingCell.renderPDFThumbnail(at: url, size: pdfSize)
            case .markdown, .text, .generic:
                // Unreachable — the guard at the top of applyFileAttachment
                // routes these kinds to the card path. Required for switch
                // exhaustiveness on the non-frozen Kind enum.
                image = nil
            }
            DispatchQueue.main.async {
                guard let self = self, self.currentAttachmentId == id else { return }
                self.attachmentImageView.image = image
                if kind == .pdf {
                    // PDFs aren't full-bleed — center the rendered page inside
                    // the bubble so blank margins are obvious as such.
                    self.attachmentImageView.contentMode = .scaleAspectFit
                    self.attachmentImageView.backgroundColor = UIColor.systemBackground
                }
            }
        }
    }

    /// Render the file-preview card path for non-image/PDF attachments —
    /// markdown, source code, plain text, and the generic catch-all. The
    /// card itself (`FilePreviewCardView`) handles all the internal layout;
    /// this method only positions it inside the cell and stashes the
    /// metadata the tap handler needs.
    private func applyFilePreviewCardAttachment(_ attachment: FileAttachment,
                                                accompanyingText: String,
                                                role: String) {
        currentAttachmentId = attachment.id
        currentAttachmentFileURL = attachment.fileURL

        profileImageView.isHidden = true
        animatingtextView.isHidden = true
        actionButton.isHidden = true
        shimmerLabel.isHidden = true
        modelLabel.isHidden = true
        attachmentErrorLabel.isHidden = true
        downloadButton.isHidden = true
        retryButton.isHidden = true
        attachmentSpinner.stopAnimating()
        attachmentSpinner.isHidden = true
        attachmentImageView.isHidden = true

        let hasText = !accompanyingText.isEmpty
        textView.isHidden = !hasText

        if filePreviewCard.superview == nil {
            contentView.addSubview(filePreviewCard)
        }
        filePreviewCard.isHidden = false
        filePreviewCard.configure(for: attachment)

        // Card pins to the user edge for user uploads, the assistant edge
        // when the model shares a file via share_file (role = "function") or
        // when the assistant attaches one directly. Width is fixed; height
        // is intrinsic and driven by the card's snippet line count.
        let isUserSide = (role == "user")
        let cardWidth: CGFloat = 240
        var constraints: [NSLayoutConstraint] = [
            filePreviewCard.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            filePreviewCard.widthAnchor.constraint(equalToConstant: cardWidth),
        ]
        if isUserSide {
            constraints.append(
                filePreviewCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10)
            )
        } else {
            constraints.append(
                filePreviewCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20)
            )
        }

        if hasText {
            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.textContainerInset = .init(top: 8, left: 10, bottom: 8, right: 10)
            textView.textContainer.lineFragmentPadding = 0
            textView.textContainer.maximumNumberOfLines = 0
            textView.textContainer.widthTracksTextView = true
            textView.layer.cornerRadius = 10
            textView.layer.borderWidth = isUserSide ? 2 : 0
            textView.layer.borderColor = UIColor.systemFill.cgColor
            textView.font = UIFont.preferredFont(forTextStyle: .body)
            textView.alpha = 1
            textView.isScrollEnabled = false
            textView.isEditable = false
            textView.attributedText = self.attributedString(from: accompanyingText)

            constraints += [
                textView.topAnchor.constraint(equalTo: filePreviewCard.bottomAnchor, constant: 6),
                textView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.8, constant: -40),
                textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            ]
            if isUserSide {
                constraints.append(
                    textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10)
                )
            } else {
                constraints.append(
                    textView.leadingAnchor.constraint(equalTo: filePreviewCard.leadingAnchor)
                )
            }
        } else {
            constraints.append(
                contentView.bottomAnchor.constraint(greaterThanOrEqualTo: filePreviewCard.bottomAnchor, constant: 12)
            )
        }

        filePreviewCardConstraints = constraints
        NSLayoutConstraint.activate(constraints)
    }

    /// Tap on the preview card. Markdown opens in the in-app editor for a
    /// nicer styled-source experience; everything else hands off to
    /// QuickLook, which gracefully falls back to the system handler when it
    /// can't render the file itself (zips, .docx, etc.).
    @objc private func handleFilePreviewCardTap() {
        guard let url = currentAttachmentFileURL else { return }
        if currentAttachmentKind == .markdown,
           MarkdownEditorViewController.isMarkdownFile(url),
           FileManager.default.fileExists(atPath: url.path),
           let presenter = parentViewController {
            MarkdownEditorViewController.present(for: url, from: presenter)
            return
        }
        presentQuickLook(for: url)
    }

    /// Render page 1 of a PDF as a UIImage sized to fit the bubble. Returns
    /// nil for malformed or empty PDFs — caller handles the placeholder.
    private static func renderPDFThumbnail(at url: URL, size: CGSize) -> UIImage? {
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
        let pageRect = page.bounds(for: .mediaBox)
        let scale = min(size.width / pageRect.width, size.height / pageRect.height)
        let target = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            ctx.cgContext.translateBy(x: 0, y: target.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
    }

    // MARK: - Inline map rendering (MapsSkill)

    /// Lay out the map bubble: optional caption above an MKMapView fitted to
    /// the place set. Each pin renders a callout with the place name + an
    /// info button that hands off to Apple Maps.
    private func applyMapAttachment(_ attachment: MapAttachment,
                                    modelLabelText: String) {
        currentMapAttachmentId = attachment.id

        profileImageView.isHidden = true
        textView.isHidden = true
        animatingtextView.isHidden = true
        actionButton.isHidden = true
        shimmerLabel.isHidden = true
        modelLabel.isHidden = false

        if mapView.superview == nil {
            self.addViews(views: [mapTitleLabel, mapView])
        }

        let hasTitle = (attachment.title?.isEmpty == false)
        if hasTitle {
            mapTitleLabel.text = attachment.title
            mapTitleLabel.isHidden = false
        } else {
            mapTitleLabel.isHidden = true
            mapTitleLabel.text = nil
        }
        mapView.isHidden = false

        // Drop any stale pins (defensive — prepareForReuse usually handles
        // this, but setData can run on a non-recycled cell during animation
        // re-renders too).
        mapView.removeAnnotations(mapView.annotations)
        let annotations: [MapPlaceAnnotation] = attachment.places.map {
            MapPlaceAnnotation(place: $0)
        }
        mapView.addAnnotations(annotations)

        // Fit the camera to all pins with a little inset so they aren't flush
        // to the bubble edge. showAnnotations handles both the single-pin
        // case (zooms to a neighborhood radius) and multi-pin (fits the box).
        mapView.showAnnotations(annotations, animated: false)

        // Bubble dimensions — same 240px logical "card width" the image
        // bubble uses, slightly taller to give the map breathing room.
        let mapHeight: CGFloat = 220

        if hasTitle {
            mapConstraints = [
                mapTitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
                mapTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
                mapTitleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),

                mapView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
                mapView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
                mapView.topAnchor.constraint(equalTo: mapTitleLabel.bottomAnchor, constant: 8),
                mapView.heightAnchor.constraint(equalToConstant: mapHeight),

                modelLabel.leadingAnchor.constraint(equalTo: mapView.leadingAnchor),
                modelLabel.topAnchor.constraint(equalTo: mapView.bottomAnchor, constant: 6),
                contentView.bottomAnchor.constraint(greaterThanOrEqualTo: modelLabel.bottomAnchor, constant: 12),
            ]
        } else {
            mapConstraints = [
                mapView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
                mapView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
                mapView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
                mapView.heightAnchor.constraint(equalToConstant: mapHeight),

                modelLabel.leadingAnchor.constraint(equalTo: mapView.leadingAnchor),
                modelLabel.topAnchor.constraint(equalTo: mapView.bottomAnchor, constant: 6),
                contentView.bottomAnchor.constraint(greaterThanOrEqualTo: modelLabel.bottomAnchor, constant: 12),
            ]
        }
        NSLayoutConstraint.activate(mapConstraints)

        baseModelText = modelLabelText
        modelLabel.text = modelLabelText
        modelLabel.textColor = .secondaryLabel
        modelLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
        modelLabel.numberOfLines = 1
        ttsIndicator.stopAnimating()
        ttsIndicator.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError()
    }
}

// MARK: - Map annotation + delegate

/// MKPointAnnotation subclass that carries the underlying MapPlace so the
/// callout-tap handler can build an MKMapItem without going through a
/// separate lookup table.
private final class MapPlaceAnnotation: MKPointAnnotation {
    let place: MapPlace
    init(place: MapPlace) {
        self.place = place
        super.init()
        self.coordinate = CLLocationCoordinate2D(latitude: place.latitude,
                                                 longitude: place.longitude)
        self.title = place.name
        self.subtitle = place.address
    }
}

extension MessagingCell: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView,
                 viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard annotation is MapPlaceAnnotation else { return nil }
        let v = mapView.dequeueReusableAnnotationView(
            withIdentifier: MessagingCell.mapPinReuseId,
            for: annotation) as? MKMarkerAnnotationView
        v?.canShowCallout = true
        v?.animatesWhenAdded = false
        // Info button on the right side of the callout — tapping it triggers
        // mapView(_:annotationView:calloutAccessoryControlTapped:).
        let button = UIButton(type: .detailDisclosure)
        button.accessibilityLabel = "Open in Maps"
        v?.rightCalloutAccessoryView = button
        return v
    }

    func mapView(_ mapView: MKMapView,
                 annotationView view: MKAnnotationView,
                 calloutAccessoryControlTapped control: UIControl) {
        guard let annotation = view.annotation as? MapPlaceAnnotation else { return }
        let placemark = MKPlacemark(coordinate: annotation.coordinate)
        let item = MKMapItem(placemark: placemark)
        item.name = annotation.place.name
        item.openInMaps(launchOptions: [
            MKLaunchOptionsMapTypeKey: NSNumber(value: MKMapType.standard.rawValue)
        ])
    }
}

extension UIView {
    var parentViewController: UIViewController? {
        var parentResponder: UIResponder? = self
        while parentResponder != nil {
            parentResponder = parentResponder?.next
            if let viewController = parentResponder as? UIViewController {
                return viewController
            }
        }
        return nil
    }
}

/// Single-item data source for QLPreviewController, used by user-uploaded
/// file attachments. Held via associated object so the preview controller
/// keeps it alive (the controller's reference to dataSource is weak).
final class MessagingCellQLSource: NSObject, QLPreviewControllerDataSource {
    /// `internal` (default) so MessagingVC can pin the source via
    /// associated object after presenting the controller — same trick
    /// the cell uses for tapped file attachments.
    static var assocKey: UInt8 = 0
    let url: URL
    init(url: URL) { self.url = url }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        return url as NSURL
    }
}

// MARK: - Tap-to-open links via SFSafariViewController

extension MessagingCell: UITextViewDelegate {
    /// iOS 17+ link interception. Tapping a link presents an in-app browser
    /// instead of bouncing the user out to Safari.
    func textView(_ textView: UITextView,
                  primaryActionFor textItem: UITextItem,
                  defaultAction: UIAction) -> UIAction? {
        if case .link(let url) = textItem.content {
            return UIAction { [weak self] _ in
                self?.openLink(url)
            }
        }
        return defaultAction
    }

    private func openLink(_ url: URL) {
        // A markdown file link opens in the in-app editor (read + edit)
        // rather than bouncing out to the Files app.
        if url.isFileURL,
           MarkdownEditorViewController.isMarkdownFile(url),
           FileManager.default.fileExists(atPath: url.path),
           let presenter = parentViewController {
            MarkdownEditorViewController.present(for: url, from: presenter)
            return
        }
        // SFSafariViewController only supports http/https. Fall back to
        // UIApplication for everything else (mailto:, tel:, custom schemes).
        let scheme = url.scheme?.lowercased()
        if scheme != "http" && scheme != "https" {
            UIApplication.shared.open(url)
            return
        }
        guard let presenter = parentViewController else {
            UIApplication.shared.open(url)
            return
        }
        let safari = SFSafariViewController(url: url)
        presenter.present(safari, animated: true)
    }
}

/// UIView whose `layer.borderColor` re-resolves through its UIColor on
/// trait collection changes. `UIView.backgroundColor` adapts to dynamic
/// UIColors automatically, but CGColors on CALayer are static — without
/// this, a table built in dark mode keeps a dark border after a switch
/// to light mode and vice versa.
final class AdaptiveBorderView: UIView {
    var adaptiveBorderColor: UIColor? {
        didSet { applyBorder() }
    }

    private func applyBorder() {
        layer.borderColor = adaptiveBorderColor?.resolvedColor(with: traitCollection).cgColor
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        applyBorder()
    }
}

/// Inset-aware UILabel used for the small language badge in the preview
/// card header (e.g. "SWIFT", "JSON"). UILabel doesn't natively support
/// content padding; subclassing is the smallest path to it.
private final class InsetLabel: UILabel {
    var contentInsets: UIEdgeInsets = .zero {
        didSet { invalidateIntrinsicContentSize() }
    }
    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + contentInsets.left + contentInsets.right,
                      height: s.height + contentInsets.top + contentInsets.bottom)
    }
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: contentInsets))
    }
}

/// File-preview card used for markdown / source / text / generic
/// attachments inside a message bubble. Self-sizing along the height axis
/// — the host (MessagingCell) pins the width to 240 and lets the card's
/// own constraints decide how tall it gets.
final class FilePreviewCardView: UIView {

    // MARK: - Public API

    /// Invoked when the user taps anywhere on the card. The host is
    /// responsible for routing (markdown → in-app editor, others →
    /// QuickLook).
    var onTap: (() -> Void)?

    /// Apply visual state for `attachment`. Call again with a new attachment
    /// to repurpose a recycled card; call `reset()` before the cell is
    /// re-rendered with a non-card attachment kind.
    func configure(for attachment: FileAttachment) {
        titleLabel.text = attachment.fileName

        // Bytes is best-effort; failure just hides the size suffix rather
        // than the whole subtitle (we still want the MIME-ish label).
        let sizeText: String?
        if let bytes = (try? attachment.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) {
            sizeText = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        } else {
            sizeText = nil
        }

        switch attachment.kind {
        case .markdown:
            iconView.image = UIImage(systemName: "doc.text")
            iconView.tintColor = .secondaryLabel
            badgeLabel.text = "MD"
            badgeLabel.isHidden = false
            subtitleLabel.text = Self.subtitle("Markdown", size: sizeText)
            applyMarkdownSnippet(attachment.extractedText ?? "")
        case .text:
            iconView.image = UIImage(systemName: "chevron.left.forwardslash.chevron.right")
            iconView.tintColor = .secondaryLabel
            if let lang = attachment.languageTag {
                badgeLabel.text = lang.uppercased()
                badgeLabel.isHidden = false
                subtitleLabel.text = Self.subtitle(lang.capitalized, size: sizeText)
            } else {
                badgeLabel.isHidden = true
                subtitleLabel.text = Self.subtitle("Text", size: sizeText)
            }
            applyCodeSnippet(attachment.extractedText ?? "")
        case .generic:
            iconView.image = UIImage(systemName: "doc")
            iconView.tintColor = .secondaryLabel
            badgeLabel.isHidden = true
            // Prefer a human label over `application/octet-stream` — fall
            // back to the uppercased extension which at least tells the
            // user what kind of blob this is.
            let mimeLabel: String
            if attachment.mimeType == "application/octet-stream" {
                let ext = attachment.fileURL.pathExtension
                mimeLabel = ext.isEmpty ? "File" : ext.uppercased()
            } else {
                mimeLabel = attachment.mimeType
            }
            subtitleLabel.text = Self.subtitle(mimeLabel, size: sizeText)
            snippetLabel.attributedText = nil
            snippetLabel.text = nil
            snippetLabel.isHidden = true
        case .image, .pdf:
            // Shouldn't happen — the cell never routes image/PDF through
            // this view — but render a sensible placeholder if it does.
            iconView.image = UIImage(systemName: "doc")
            iconView.tintColor = .secondaryLabel
            badgeLabel.isHidden = true
            subtitleLabel.text = Self.subtitle(attachment.mimeType, size: sizeText)
            snippetLabel.isHidden = true
        }
    }

    /// Clear all the per-attachment text/badges so a recycled card doesn't
    /// flash stale content during the next configure pass. Visibility is
    /// the cell's responsibility — this only resets content.
    func reset() {
        titleLabel.text = nil
        subtitleLabel.text = nil
        badgeLabel.text = nil
        badgeLabel.isHidden = true
        snippetLabel.attributedText = nil
        snippetLabel.text = nil
        snippetLabel.isHidden = false
        iconView.image = nil
    }

    // MARK: - Subviews

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let badgeLabel = InsetLabel()
    private let subtitleLabel = UILabel()
    private let snippetLabel = UILabel()
    private let headerStack = UIStackView()

    // MARK: - Setup

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 14
        layer.borderWidth = 1
        layer.borderColor = UIColor.systemFill.cgColor
        clipsToBounds = true
        isUserInteractionEnabled = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .secondaryLabel
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.numberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        badgeLabel.textColor = .secondaryLabel
        badgeLabel.backgroundColor = .tertiarySystemFill
        badgeLabel.layer.cornerRadius = 3
        badgeLabel.layer.masksToBounds = true
        badgeLabel.textAlignment = .center
        badgeLabel.contentInsets = UIEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingMiddle

        snippetLabel.translatesAutoresizingMaskIntoConstraints = false
        snippetLabel.numberOfLines = 6
        snippetLabel.textColor = .label
        snippetLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
        snippetLabel.lineBreakMode = .byTruncatingTail

        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = 6
        headerStack.addArrangedSubview(iconView)
        headerStack.addArrangedSubview(titleLabel)
        headerStack.addArrangedSubview(badgeLabel)

        addSubview(headerStack)
        addSubview(subtitleLabel)
        addSubview(snippetLabel)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            headerStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            subtitleLabel.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            snippetLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            snippetLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            snippetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            snippetLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
        ])

        // Drive the bottom edge off whichever element is the lowest visible
        // one. snippetLabel-bottom is `lessThanOrEqualTo` above so it
        // doesn't *force* height; this constraint pulls the bottom up when
        // the snippet collapses, keeping the generic-card chip-sized.
        let bottomEqual = bottomAnchor.constraint(equalTo: snippetLabel.bottomAnchor, constant: 12)
        bottomEqual.priority = .defaultHigh
        bottomEqual.isActive = true
        let subtitleBottomEqual = bottomAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12)
        subtitleBottomEqual.priority = .defaultLow
        subtitleBottomEqual.isActive = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
    }

    @objc private func handleTap() { onTap?() }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previous) else { return }
        layer.borderColor = UIColor.systemFill.cgColor
    }

    // MARK: - Snippet rendering

    /// Render up to 6 lines of markdown source with the live highlighter so
    /// the preview reads like the editor will when opened. Operates on the
    /// truncated prefix only — the highlighter's regex passes are linear so
    /// trimming first keeps redraws cheap on long files.
    private func applyMarkdownSnippet(_ text: String) {
        if text.isEmpty {
            snippetLabel.isHidden = true
            snippetLabel.attributedText = nil
            return
        }
        let snippet = Self.firstLines(text, count: 6)
        let storage = NSTextStorage(string: snippet)
        MarkdownSourceHighlighter.highlight(storage, baseSize: 12)
        snippetLabel.attributedText = storage
        snippetLabel.isHidden = false
    }

    /// Render up to 8 lines of source/text content in a monospaced font.
    /// No syntax tokenization — language-aware highlighting belongs in the
    /// full file viewer; here we just need "this looks like code."
    private func applyCodeSnippet(_ text: String) {
        if text.isEmpty {
            snippetLabel.isHidden = true
            snippetLabel.attributedText = nil
            return
        }
        let snippet = Self.firstLines(text, count: 8)
        let attributed = NSAttributedString(string: snippet, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: UIColor.label,
        ])
        snippetLabel.attributedText = attributed
        snippetLabel.numberOfLines = 8
        snippetLabel.isHidden = false
    }

    private static func firstLines(_ text: String, count: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(count)
        return lines.joined(separator: "\n")
    }

    private static func subtitle(_ label: String, size: String?) -> String {
        guard let size = size else { return label }
        return "\(label) · \(size)"
    }
}
