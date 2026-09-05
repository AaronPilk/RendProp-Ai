import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore
import UIKit

/// Builds the CALayer that `AVVideoCompositionCoreAnimationTool` animates:
/// social-style burned-in captions, one line on screen at a time, word-by-word
/// highlight optional.
///
/// ## How C must mount this layer (matches the existing title-card path exactly)
///
/// ```swift
/// let parentLayer = CALayer(); parentLayer.frame = renderRect
/// parentLayer.isGeometryFlipped = true        // ← already true in stitch()
/// parentLayer.addSublayer(videoLayer)
/// parentLayer.addSublayer(overlayLayer)       // captions go in here
/// overlayLayer.addSublayer(CaptionRenderer.layer(...))
/// ```
///
/// The returned layer lays its text out in **top-left** coordinates and does
/// NOT set `isGeometryFlipped` itself — it inherits the flip from the parent
/// `stitch()` already builds. Setting the flip a second time on this layer
/// would flip the tree back and render the captions mirrored, so don't.
///
/// ## The Core Animation rules this file obeys (all four are silent killers)
///
/// 1. `beginTime` is always `AVCoreAnimationBeginTimeAtZero + t`. A literal 0.0
///    means "now" to Core Animation and the animation never renders offline.
/// 2. `isRemovedOnCompletion = false` — the export walks the timeline once and
///    an animation that removed itself takes its value with it.
/// 3. `fillMode = .both` — the value is pinned before `beginTime` and after the
///    animation ends, so a line is invisible outside its own window.
/// 4. Every line layer's model `opacity` is 0 as well, so even if the backward
///    fill were ignored the captions could never be stuck on screen.
enum CaptionRenderer {

    // MARK: Tunables

    /// The contract quotes font sizes at a 1080-wide render; everything else
    /// scales off the real width.
    private static let referenceWidth: CGFloat = 1080
    /// Bottom of the caption block, as a fraction of height, in top-left
    /// coordinates: lower third, above the home indicator and above the
    /// caption/username furniture Instagram and TikTok paint over the bottom.
    private static let blockBottomFraction: CGFloat = 0.82
    private static let sideMarginFraction: CGFloat = 0.06
    private static let fadeIn: Double = 0.18
    private static let fadeOut: Double = 0.18
    /// A line never flashes past faster than this, even if its words did.
    private static let minimumOnScreen: Double = 0.25
    /// A silence this long starts a new caption line even mid-count.
    private static let breathGap: Double = 0.6
    private static let normalColor = UIColor.white
    /// Brand purple, the brighter dark-mode variant (#9B6DFF) — it holds up
    /// against arbitrary footage far better than the light-mode purple.
    private static let accentColor = UIColor(red: 155 / 255, green: 109 / 255, blue: 255 / 255, alpha: 1)

    // MARK: Entry point (contract)

    /// - Parameters:
    ///   - words: timings relative to the voiceover start
    ///   - offset: where the voiceover starts inside the reel (usually 0)
    ///   - renderSize: the composition size (1080x1920 or 1920x1080)
    /// - Returns: a layer sized to renderSize with keyframed opacity per line.
    static func layer(words: [CaptionWord], offset: Double,
                      renderSize: CGSize, style: CaptionStyle) -> CALayer {
        let root = CALayer()
        guard renderSize.width.isFinite, renderSize.height.isFinite,
              renderSize.width > 0, renderSize.height > 0 else { return root }
        root.frame = CGRect(origin: .zero, size: renderSize)
        root.masksToBounds = false          // shadows/haloes must not clip
        root.isGeometryFlipped = false      // inherit the parent's flip — see the class note

        let shift = offset.isFinite ? offset : 0
        let cleaned = sanitize(words, offset: shift)
        guard style.enabled, !cleaned.isEmpty else { return root }

        let scale = renderSize.width / referenceWidth
        let nominalSize = style.fontSize.isFinite && style.fontSize > 0 ? style.fontSize : 64
        // Width-proportional per the contract, then capped against HEIGHT so a
        // landscape 1920x1080 render (scale 1.78) can't produce type taller than
        // the frame can hold.
        let fontSize = min(max(nominalSize * scale, 12), renderSize.height * 0.085)
        let margin = renderSize.width * sideMarginFraction
        let maxTextWidth = max(renderSize.width - margin * 2, fontSize)

        let groups = lineGroups(cleaned, maxWordsPerLine: style.maxWordsPerLine)
        for (index, group) in groups.enumerated() {
            let nextStart = index + 1 < groups.count ? groups[index + 1].first?.start : nil
            guard let window = window(for: group, nextLineStart: nextStart) else { continue }
            let line = lineLayer(group, window: window, fontSize: fontSize,
                                 maxTextWidth: maxTextWidth, renderSize: renderSize,
                                 highlight: style.highlightActiveWord)
            root.addSublayer(line)
        }
        return root
    }

    // MARK: Words → lines

    /// Drop unusable timings, apply `offset`, and put the words in time order.
    /// (B's ElevenLabs alignment and Apple's segments both feed this; neither is
    /// guaranteed sorted or finite.)
    static func sanitize(_ words: [CaptionWord], offset: Double) -> [CaptionWord] {
        words.compactMap { word -> CaptionWord? in
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, word.start.isFinite, word.end.isFinite else { return nil }
            let start = max(0, word.start + offset)
            let end = max(start + 0.05, word.end + offset)
            return CaptionWord(text: text, start: start, end: end)
        }
        .sorted { $0.start < $1.start }
    }

    /// Chunk into lines of at most `maxWordsPerLine`, breaking early on a
    /// sentence end or a breath — captions that ignore punctuation read wrong.
    static func lineGroups(_ words: [CaptionWord], maxWordsPerLine: Int) -> [[CaptionWord]] {
        let limit = min(max(maxWordsPerLine, 1), 8)
        var groups: [[CaptionWord]] = []
        var current: [CaptionWord] = []

        for word in words {
            if let previous = current.last {
                let brokeForBreath = word.start - previous.end > breathGap
                let brokeForSentence = previous.text.hasSuffixIn([".", "!", "?", "…"])
                if current.count >= limit || brokeForBreath || brokeForSentence {
                    groups.append(current)
                    current = []
                }
            }
            current.append(word)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// The four time points of one line, in composition seconds:
    /// t0 start fading in · t1 fully visible · t2 start fading out · t3 gone.
    struct Window {
        let t0: Double
        let t1: Double
        let t2: Double
        let t3: Double
        var duration: Double { max(t3 - t0, 0.05) }
    }

    static func window(for group: [CaptionWord], nextLineStart: Double?) -> Window? {
        guard let first = group.first else { return nil }
        // Latest end in the group, not the last word's — overlapping timings
        // from either provider must not cut the line short.
        let lastEnd = group.map { $0.end }.max() ?? first.end
        let t1 = max(0, first.start)
        let t0 = max(0, t1 - fadeIn)
        var t3 = max(lastEnd, t1 + minimumOnScreen) + fadeOut
        // Only ever one line on screen: hand over exactly as the next one starts
        // fading in, never overlapping it. The 0.1 s floor only bites when two
        // lines start within a blink of each other, and a ≤0.1 s overlap beats
        // dropping a line's words entirely.
        if let nextLineStart {
            let nextT0 = max(0, nextLineStart - fadeIn)
            if t3 > nextT0 { t3 = max(nextT0, t0 + 0.10) }
        }
        let t2 = max(t1, t3 - fadeOut)
        guard t3 > t0 else { return nil }
        return Window(t0: t0, t1: t1, t2: t2, t3: t3)
    }

    // MARK: Drawing

    /// One caption line: a container (which carries the opacity keyframe) with
    /// a CATextLayer per word, laid out centred in the lower third. Per-word
    /// layers are what make `highlightActiveWord` possible at all — CATextLayer
    /// animates `foregroundColor`, and one layer per line could not recolour a
    /// single word inside it.
    private static func lineLayer(_ words: [CaptionWord], window: Window,
                                  fontSize: CGFloat, maxTextWidth: CGFloat,
                                  renderSize: CGSize, highlight: Bool) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: renderSize)
        container.masksToBounds = false
        container.opacity = 0                      // invisible unless its window says otherwise

        // Shrink-to-fit: heavy type at 4 words a line can overrun 1080 px, and a
        // truncated caption is worse than a slightly smaller one.
        var size = fontSize
        var rows = wrap(words, fontSize: size, maxWidth: maxTextWidth)
        var attempts = 0
        while rows.count > 2, attempts < 4, size > fontSize * 0.55 {
            size = max(size * 0.88, fontSize * 0.55)
            rows = wrap(words, fontSize: size, maxWidth: maxTextWidth)
            attempts += 1
        }

        let font = UIFont.systemFont(ofSize: size, weight: .heavy)
        let rowHeight = size * 1.24
        let blockHeight = rowHeight * CGFloat(rows.count)
        let blockTop = renderSize.height * blockBottomFraction - blockHeight
        let space = spaceWidth(font: font, size: size)
        let pad = max(2, size * 0.06)              // guards against measurement rounding

        for (rowIndex, row) in rows.enumerated() {
            let widths = row.map { measure($0.text, font: font) }
            let rowWidth = widths.reduce(0, +) + space * CGFloat(max(row.count - 1, 0))
            var x = (renderSize.width - rowWidth) / 2
            let y = blockTop + CGFloat(rowIndex) * rowHeight

            for (wordIndex, word) in row.enumerated() {
                let width = widths[wordIndex]
                let frame = CGRect(x: x - pad, y: y, width: width + pad * 2, height: rowHeight)

                // A black copy behind, blurred by its own shadow: a dark halo
                // that keeps white type legible over bright footage. Cheaper and
                // more even than a stroke, and it never animates colour.
                let halo = textLayer(word.text, font: font, size: size, color: .black, frame: frame)
                halo.shadowColor = UIColor.black.cgColor
                halo.shadowOpacity = 1
                halo.shadowRadius = size * 0.16
                halo.shadowOffset = .zero
                container.addSublayer(halo)

                let text = textLayer(word.text, font: font, size: size, color: normalColor, frame: frame)
                text.shadowColor = UIColor.black.cgColor
                text.shadowOpacity = 0.85
                text.shadowRadius = max(2, size * 0.10)
                text.shadowOffset = CGSize(width: 0, height: max(1, size * 0.04))
                if highlight, let colorAnimation = highlightAnimation(for: word, window: window) {
                    text.add(colorAnimation, forKey: "captionWordHighlight")
                }
                container.addSublayer(text)

                x += width + space
            }
        }

        container.add(opacityAnimation(window), forKey: "captionLineOpacity")
        return container
    }

    private static func textLayer(_ string: String, font: UIFont, size: CGFloat,
                                  color: UIColor, frame: CGRect) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = string
        layer.font = font                 // UIFont is toll-free bridged to CTFont
        layer.fontSize = size
        layer.foregroundColor = color.cgColor
        layer.alignmentMode = .center
        layer.isWrapped = false
        layer.truncationMode = .end
        layer.contentsScale = 2           // oversample so glyph edges stay crisp
        layer.frame = frame
        return layer
    }

    /// Fade in, hold, fade out — in the composition's time base.
    private static func opacityAnimation(_ window: Window) -> CAKeyframeAnimation {
        let duration = window.duration
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0.0, 1.0, 1.0, 0.0]
        animation.keyTimes = [
            0,
            NSNumber(value: clamp01((window.t1 - window.t0) / duration)),
            NSNumber(value: clamp01((window.t2 - window.t0) / duration)),
            1
        ]
        animation.beginTime = AVCoreAnimationBeginTimeAtZero + window.t0
        animation.duration = duration
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// White → accent → white across this word's slice of the line's window.
    /// `.discrete` needs one MORE keyTime than values (Apple's rule), hence four
    /// key times for three colours.
    private static func highlightAnimation(for word: CaptionWord, window: Window) -> CAKeyframeAnimation? {
        let duration = window.duration
        let start = clamp01((word.start - window.t0) / duration)
        let end = clamp01((word.end - window.t0) / duration)
        guard end > start else { return nil }

        let animation = CAKeyframeAnimation(keyPath: "foregroundColor")
        animation.values = [normalColor.cgColor, accentColor.cgColor, normalColor.cgColor]
        animation.keyTimes = [0, NSNumber(value: start), NSNumber(value: end), 1]
        animation.calculationMode = .discrete
        animation.beginTime = AVCoreAnimationBeginTimeAtZero + window.t0
        animation.duration = duration
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        return animation
    }

    // MARK: Measuring

    /// Greedy wrap into rows that fit `maxWidth`. Two rows is the practical
    /// ceiling for a social caption; a single word wider than the frame is left
    /// on its own row and the caller's shrink loop deals with it.
    private static func wrap(_ words: [CaptionWord], fontSize: CGFloat,
                             maxWidth: CGFloat) -> [[CaptionWord]] {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
        let space = spaceWidth(font: font, size: fontSize)
        var rows: [[CaptionWord]] = []
        var row: [CaptionWord] = []
        var rowWidth: CGFloat = 0

        for word in words {
            let width = measure(word.text, font: font)
            let candidate = row.isEmpty ? width : rowWidth + space + width
            if !row.isEmpty, candidate > maxWidth {
                rows.append(row)
                row = [word]
                rowWidth = width
            } else {
                row.append(word)
                rowWidth = candidate
            }
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    /// Width of one space. Some text-measuring paths trim whitespace and hand
    /// back 0, which would run every word together — floor it at a sane fraction
    /// of the em instead.
    private static func spaceWidth(font: UIFont, size: CGFloat) -> CGFloat {
        max(measure(" ", font: font), size * 0.26)
    }

    private static func measure(_ string: String, font: UIFont) -> CGFloat {
        let width = (string as NSString).size(withAttributes: [.font: font]).width
        return width.isFinite ? ceil(width) : 0
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

private extension String {
    func hasSuffixIn(_ suffixes: [String]) -> Bool {
        suffixes.contains { hasSuffix($0) }
    }
}
