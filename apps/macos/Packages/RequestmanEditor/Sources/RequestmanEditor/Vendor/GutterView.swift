// Adapted from CodeEditSourceEditor 0.15.2 (MIT); see ThirdPartyNotices.md.
// Changes: remove folding/controller dependencies; use owner-driven invalidation,
// the text fragment baseline, and a native gutter separator.
//
//  GutterView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 8/22/23.
//

import AppKit
import CodeEditTextView
import CodeEditTextViewObjC

@MainActor public protocol GutterViewDelegate: AnyObject {
    func gutterViewWidthDidUpdate()
}

/// The gutter view displays line numbers that match the text view's line indexes.
/// This view is used as a scroll view's ruler view. It sits on top of the text view so text scrolls underneath the
/// gutter if line wrapping is disabled.
///
/// If the gutter needs more space (when the number of digits in the numbers increases eg. adding a line after line 99),
/// it will notify it's delegate via the ``GutterViewDelegate/gutterViewWidthDidUpdate(newWidth:)`` method. In
/// `SourceEditor`, this notifies the ``TextViewController``, which in turn updates the textview's edge insets
/// to adjust for the new leading inset.
///
/// This view also listens for selection updates, and draws a selected background on selected lines to keep the illusion
/// that the gutter's line numbers are inline with the line itself.
///
/// The gutter view has insets of it's own that are relative to the widest line index. By default, these insets are 20px
/// leading, and 12px trailing. However, this view also has a ``GutterView/backgroundEdgeInsets`` property, that pads
/// the rect that has a background drawn. This allows the text to be scrolled under the gutter view for 8px before being
/// overlapped by the gutter. It should help the textview keep the cursor visible if the user types while the cursor is
/// off the leading edge of the editor.
///
public class GutterView: NSView {
    struct EdgeInsets: Equatable, Hashable {
        let leading: CGFloat
        let trailing: CGFloat

        var horizontal: CGFloat {
            leading + trailing
        }
    }

    var textColor: NSColor = .secondaryLabelColor

    var font: NSFont = .systemFont(ofSize: 13)

    var edgeInsets: EdgeInsets = EdgeInsets(leading: 20, trailing: 12)

    var backgroundEdgeInsets: EdgeInsets = EdgeInsets(leading: 0, trailing: 8)

    var backgroundColor: NSColor? = NSColor.controlBackgroundColor

    var highlightSelectedLines: Bool = true

    var selectedLineTextColor: NSColor? = .labelColor

    private weak var textView: TextView?
    private weak var delegate: GutterViewDelegate?
    private var maxLineNumberWidth: CGFloat = 0
    /// The maximum number of digits found for a line number.
    private var maxLineLength: Int = 0

    private let foldingRibbonWidth: CGFloat = 0

    /// The gutter's y positions start at the top of the document and increase as it moves down the screen.
    override public var isFlipped: Bool {
        true
    }

    public init(
        font: NSFont,
        textColor: NSColor,
        selectedTextColor: NSColor?,
        textView: TextView,
        delegate: GutterViewDelegate? = nil
    ) {
        self.font = font
        self.textColor = textColor
        self.selectedLineTextColor = selectedTextColor ?? .secondaryLabelColor
        self.textView = textView
        self.delegate = delegate


        super.init(frame: .zero)
        clipsToBounds = true
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        layer?.masksToBounds = true

        let separator = NSBox()
        separator.boxType = .separator
        separator.identifier = .init("editor.gutterSeparator")
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Updates the width of the gutter if needed to match the maximum line number found as well as the folding ribbon.
    func updateWidthIfNeeded() {
        guard let textView else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        // Reserve at least 3 digits of space no matter what
        let lineStorageDigits = max(3, String(textView.layoutManager.lineCount).count)

        if maxLineLength < lineStorageDigits {
            // Update the max width
            let maxCtLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: String(repeating: "0", count: lineStorageDigits), attributes: attributes)
            )
            let width = CTLineGetTypographicBounds(maxCtLine, nil, nil, nil)
            maxLineNumberWidth = max(maxLineNumberWidth, width)
            maxLineLength = lineStorageDigits
        }

        let newWidth = maxLineNumberWidth + edgeInsets.horizontal + foldingRibbonWidth
        if frame.size.width != newWidth {
            frame.size.width = newWidth
            delegate?.gutterViewWidthDidUpdate()
        }
    }

    /// Fills the gutter background color.
    /// - Parameters:
    ///   - context: The drawing context to draw in.
    ///   - dirtyRect: A rect to draw in, received from ``draw(_:)``.
    private func drawBackground(_ context: CGContext, dirtyRect: NSRect) {
        guard let backgroundColor else { return }
        let minX = max(backgroundEdgeInsets.leading, dirtyRect.minX)
        let maxX = min(frame.width - backgroundEdgeInsets.trailing - foldingRibbonWidth, dirtyRect.maxX)
        let width = maxX - minX

        context.saveGState()
        context.setFillColor(backgroundColor.cgColor)
        context.fill(CGRect(x: minX, y: dirtyRect.minY, width: width, height: dirtyRect.height))
        context.restoreGState()
    }

    /// Draws selected line backgrounds from the text view's selection manager into the gutter view, making the
    /// selection background appear seamless between the gutter and text view.
    /// - Parameter context: The drawing context to use.
    private func drawSelectedLines(_ context: CGContext) {
        guard let textView = textView,
              let selectionManager = textView.selectionManager,
              let visibleRange = textView.visibleTextRange,
              highlightSelectedLines else {
            return
        }
        context.saveGState()

        var highlightedLines: Set<UUID> = []
        context.setFillColor(selectionManager.selectedLineBackgroundColor.cgColor)

        let xPos = backgroundEdgeInsets.leading
        let width = frame.width - backgroundEdgeInsets.trailing

        for selection in selectionManager.textSelections where selection.range.isEmpty {
            guard let line = textView.layoutManager.textLineForOffset(selection.range.location),
                  visibleRange.intersection(line.range) != nil || selection.range.location == textView.textStorage.length,
                  !highlightedLines.contains(line.data.id) else {
                continue
            }
            highlightedLines.insert(line.data.id)
            // Use the same document-space pixel alignment as the text selection renderer.
            let lineRect = CGRect(x: 0, y: line.yPos, width: width, height: line.height).pixelAligned
            let gutterRect = convert(lineRect, from: textView)
            context.fill(CGRect(x: xPos, y: gutterRect.minY, width: width, height: gutterRect.height))
        }

        context.restoreGState()
    }

    /// Draw line numbers in the gutter, limited to a drawing rect.
    /// - Parameters:
    ///   - context: The drawing context to draw in.
    ///   - dirtyRect: A rect to draw in, received from ``draw(_:)``.
    private func drawLineNumbers(_ context: CGContext, dirtyRect: NSRect) {
        guard let textView = textView else { return }
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let currentLineIDs = Set(textView.selectionManager.textSelections.compactMap { selection in
            selection.range.isEmpty ? textView.layoutManager.textLineForOffset(selection.range.location)?.data.id : nil
        })

        var selectionRangeMap = IndexSet()
        textView.selectionManager?.textSelections.forEach {
            if $0.range.isEmpty {
                selectionRangeMap.insert($0.range.location)
            } else {
                selectionRangeMap.insert(integersIn: $0.range.location..<NSMaxRange($0.range))
            }
        }

        context.saveGState()
        context.clip(to: dirtyRect)

        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let textRect = convert(dirtyRect, to: textView)
        for linePosition in textView.layoutManager.linesStartingAt(textRect.minY, until: textRect.maxY) {
            let isCurrentLine = currentLineIDs.contains(linePosition.data.id)
            attributes[.font] = isCurrentLine ? boldFont : font
            if isCurrentLine || selectionRangeMap.intersects(integersIn: linePosition.range) {
                attributes[.foregroundColor] = selectedLineTextColor ?? textColor
            } else {
                attributes[.foregroundColor] = textColor
            }

            let ctLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: "\(linePosition.index + 1)", attributes: attributes)
            )
            guard let fragment = linePosition.data.lineFragments.first?.data else { continue }
            let lineNumberWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            let baseline: CGFloat
            if linePosition.range.isEmpty {
                // Empty placeholder fragments have no font descent. Center the number's
                // visible glyphs in the row instead of treating that placeholder as text.
                let glyphBounds = CTLineGetBoundsWithOptions(ctLine, .useGlyphPathBounds)
                baseline = CGPoint(x: 0, y: linePosition.height / 2 + glyphBounds.midY).pixelAligned.y
            } else {
                // Match LineFragmentRenderer's baseline, including its local pixel alignment.
                baseline = CGPoint(x: 0, y: fragment.height - fragment.descent + fragment.heightDifference / 2).pixelAligned.y
            }
            let yPos = convert(NSPoint(x: 0, y: linePosition.yPos + baseline), from: textView).y
            // Leading padding + (width - linewidth)
            let xPos = edgeInsets.leading + (maxLineNumberWidth - lineNumberWidth)

            ContextSetHiddenSmoothingStyle(context, 16)

            context.textPosition = CGPoint(x: xPos, y: yPos)

            CTLineDraw(ctLine, context)
        }
        context.restoreGState()
    }

    override public func setNeedsDisplay(_ invalidRect: NSRect) {
        updateWidthIfNeeded()
        super.setNeedsDisplay(invalidRect)
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }
        context.saveGState()
        drawBackground(context, dirtyRect: dirtyRect)
        drawSelectedLines(context)
        drawLineNumbers(context, dirtyRect: dirtyRect)
        context.restoreGState()
    }

}
