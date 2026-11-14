import AppKit

struct StatusPart: Equatable {
    let text: String
    let style: StatusSegmentStyle?
    let isCurrent: Bool
    var workspaceIndex: Int? = nil
    var symbolName: String? = nil
}

struct StatusWorkspaceHitRegion: Equatable {
    let index: Int
    let rect: NSRect
}

struct StatusRenderOutput {
    let image: NSImage
    let workspaceRegions: [StatusWorkspaceHitRegion]
}

private func statusColor(_ hex: String?) -> NSColor? {
    guard let hex else { return nil }
    let digits = String(hex.dropFirst())
    guard let value = UInt64(digits,radix:16) else { return nil }
    let rgba = digits.count == 8 ? value : (value << 8) | 0xff
    return NSColor(srgbRed:CGFloat((rgba >> 24) & 255)/255,
                   green:CGFloat((rgba >> 16) & 255)/255,
                   blue:CGFloat((rgba >> 8) & 255)/255,
                   alpha:CGFloat(rgba & 255)/255)
}

private struct SegmentMetrics {
    let part: StatusPart
    let font: NSFont
    let symbolImage: NSImage?
    let displayText: String
    let contentWidth: CGFloat
    var leftPad: CGFloat = 0
    var rightPad: CGFloat = 0
    var totalWidth: CGFloat { contentWidth + leftPad + rightPad }
}

private struct ChromeRunKey: Equatable {
    let background: String?
    let box: StatusBoxStyle?
    let workspaceIndex: Int?
    var hasChrome: Bool { background != nil || box != nil }
}

private func resolveSymbolImage(name: String, pointSize: CGFloat, current: Bool) -> NSImage? {
    let weight: NSFont.Weight = current ? .semibold : .medium
    let symConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(symConfig)
}

private func drawTintedSymbol(_ symbol: NSImage, in rect: NSRect, color: NSColor) {
    let tinted = NSImage(size: rect.size, flipped: false) { bounds in
        symbol.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
        color.setFill()
        bounds.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
}

/// Renders the menu bar item as a crisp vector image and returns clickable workspace hit regions.
func renderConfiguredStatus(
    parts: [StatusPart],
    dark: Bool,
    showIcon: Bool = true,
    hoveredWorkspace: Int? = nil
) -> StatusRenderOutput {
    var segments: [SegmentMetrics] = parts.map { part in
        let size = CGFloat(part.style?.fontSize ?? 11.5)
        let font = part.style?.font.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.monospacedDigitSystemFont(ofSize: size, weight: part.isCurrent ? .semibold : .medium)
        if let symName = part.symbolName {
            if let symImg = resolveSymbolImage(name: symName, pointSize: size * 0.98, current: part.isCurrent) {
                let slotW = max(16, ceil(symImg.size.width))
                return SegmentMetrics(part: part, font: font, symbolImage: symImg, displayText: "", contentWidth: slotW)
            }
            let textW = ceil((symName as NSString).size(withAttributes: [.font: font]).width)
            return SegmentMetrics(part: part, font: font, symbolImage: nil, displayText: symName, contentWidth: textW)
        }
        let textW = ceil((part.text as NSString).size(withAttributes: [.font: font]).width)
        return SegmentMetrics(part: part, font: font, symbolImage: nil, displayText: part.text, contentWidth: textW)
    }

    // Group consecutive segments sharing identical background/box/workspace into unified pill runs
    var runs: [(range: Range<Int>, key: ChromeRunKey)] = []
    var idx = 0
    while idx < segments.count {
        let style = segments[idx].part.style
        let key = ChromeRunKey(background: style?.background, box: style?.box, workspaceIndex: segments[idx].part.workspaceIndex)
        var end = idx + 1
        if key.hasChrome {
            while end < segments.count {
                let nextStyle = segments[end].part.style
                let nextKey = ChromeRunKey(background: nextStyle?.background, box: nextStyle?.box, workspaceIndex: segments[end].part.workspaceIndex)
                if nextKey == key { end += 1 } else { break }
            }
        }
        runs.append((idx..<end, key))
        idx = end
    }

    for run in runs where run.key.background != nil || run.key.box?.type == .full {
        let slice = segments[run.range]
        let hasVisible = slice.contains { $0.symbolImage != nil || !$0.displayText.trimmingCharacters(in: .whitespaces).isEmpty }
        guard hasVisible, let firstIdx = run.range.first, let lastIdx = run.range.last else { continue }
        let firstText = segments[firstIdx].displayText
        let lastText = segments[lastIdx].displayText
        segments[firstIdx].leftPad = (segments[firstIdx].symbolImage == nil && firstText.hasPrefix(" ")) ? 2.5 : 6.0
        segments[lastIdx].rightPad = (segments[lastIdx].symbolImage == nil && lastText.hasSuffix(" ")) ? 2.5 : 6.0
    }

    let leading: CGFloat = showIcon ? 22 : 0
    let rawWidth = leading + segments.reduce(0) { $0 + $1.totalWidth }
    let width = max(1, min(460, ceil(rawWidth)))

    var segStarts: [CGFloat] = []
    segStarts.reserveCapacity(segments.count)
    var workspaceRegions: [StatusWorkspaceHitRegion] = []
    var cursorX: CGFloat = leading
    for seg in segments {
        segStarts.append(cursorX)
        if cursorX < width, let wsIdx = seg.part.workspaceIndex {
            let segW = min(seg.totalWidth, width - cursorX)
            let rect = NSRect(x: cursorX, y: 0, width: segW, height: 18)
            if let last = workspaceRegions.last, last.index == wsIdx {
                workspaceRegions[workspaceRegions.count - 1] = StatusWorkspaceHitRegion(
                    index: wsIdx,
                    rect: last.rect.union(rect)
                )
            } else {
                workspaceRegions.append(StatusWorkspaceHitRegion(index: wsIdx, rect: rect))
            }
        }
        cursorX += seg.totalWidth
    }

    let image = NSImage(size: NSSize(width: width, height: 18), flipped: false) { _ in
        let defaultInk = dark ? NSColor.white : NSColor(calibratedWhite: 0.08, alpha: 1)
        defaultInk.withAlphaComponent(0.92).setFill()
        func tile(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: 1.4, yRadius: 1.4).fill()
        }
        if showIcon { tile(1.5, 2, 7.75, 14); tile(10.5, 9.625, 6, 6.375); tile(10.5, 2, 6, 6.375) }

        // Draw hover pill behind hovered workspace when it has no explicit pill background
        if let hoveredWorkspace,
           let region = workspaceRegions.first(where: { $0.index == hoveredWorkspace }) {
            let hasOwnBg = segments.contains {
                $0.part.workspaceIndex == hoveredWorkspace && $0.part.style?.background != nil
            }
            if !hasOwnBg {
                let hoverRect = NSRect(
                    x: max(0, region.rect.minX - 1),
                    y: 1,
                    width: min(width - max(0, region.rect.minX - 1), region.rect.width + 2),
                    height: 16
                )
                let hoverColor = dark
                    ? NSColor.white.withAlphaComponent(0.15)
                    : NSColor.black.withAlphaComponent(0.08)
                hoverColor.setFill()
                NSBezierPath(roundedRect: hoverRect, xRadius: 8, yRadius: 8).fill()
            }
        }

        func resolveForeground(_ style: StatusSegmentStyle?) -> NSColor {
            let defaultAlpha: CGFloat = (style?.dimmed == true) ? (dark ? 0.54 : 0.48) : 0.92
            var fg = statusColor(style?.foreground) ?? defaultInk.withAlphaComponent(defaultAlpha)
            if style?.dimmed == true && style?.foreground != nil {
                fg = fg.withAlphaComponent(fg.alphaComponent * 0.62)
            }
            return fg
        }

        // 1. Draw unified background pills and <box> chrome per run
        for run in runs where run.key.hasChrome {
            guard let firstIdx = run.range.first else { continue }
            let runX = segStarts[firstIdx]
            guard runX < width else { continue }
            let runW = segments[run.range].reduce(0) { $0 + $1.totalWidth }
            let pillRect = NSRect(x: runX, y: 1, width: runW, height: 16)
            let pillRadius = min(pillRect.height / 2, CGFloat(run.key.box?.radius ?? 8.0))
            let repStyle = segments[firstIdx].part.style
            let repFg = resolveForeground(repStyle)

            if let background = statusColor(run.key.background) {
                background.setFill()
                NSBezierPath(roundedRect: pillRect, xRadius: pillRadius, yRadius: pillRadius).fill()
                if let hoveredWorkspace, run.key.workspaceIndex == hoveredWorkspace {
                    let gloss = dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.white.withAlphaComponent(0.22)
                    gloss.setFill()
                    NSBezierPath(roundedRect: pillRect, xRadius: pillRadius, yRadius: pillRadius).fill()
                }
            }

            if let box = run.key.box {
                let boxColor = statusColor(box.color) ?? repFg
                let lw = CGFloat(box.width)
                boxColor.setFill()
                boxColor.setStroke()
                switch box.type {
                case .full:
                    let insetRect = pillRect.insetBy(dx: lw / 2, dy: lw / 2)
                    let r = max(0, pillRadius - lw / 2)
                    let borderPath = NSBezierPath(roundedRect: insetRect, xRadius: r, yRadius: r)
                    borderPath.lineWidth = lw
                    borderPath.stroke()
                case .bottom, .top, .hBoth:
                    let barInset = min(3.5, runW * 0.14)
                    let barW = max(2, runW - barInset * 2)
                    let barX = runX + barInset
                    let barRadius = CGFloat(box.radius ?? Double(lw / 2))
                    if box.type == .bottom || box.type == .hBoth {
                        NSBezierPath(
                            roundedRect: NSRect(x: barX, y: 0.75, width: barW, height: lw),
                            xRadius: barRadius,
                            yRadius: barRadius
                        ).fill()
                    }
                    if box.type == .top || box.type == .hBoth {
                        NSBezierPath(
                            roundedRect: NSRect(x: barX, y: 17.25 - lw, width: barW, height: lw),
                            xRadius: barRadius,
                            yRadius: barRadius
                        ).fill()
                    }
                case .vBoth:
                    let barH: CGFloat = 12
                    let barY: CGFloat = 3
                    let barRadius = CGFloat(box.radius ?? Double(lw / 2))
                    NSBezierPath(roundedRect: NSRect(x: runX + 0.5, y: barY, width: lw, height: barH), xRadius: barRadius, yRadius: barRadius).fill()
                    NSBezierPath(roundedRect: NSRect(x: runX + runW - lw - 0.5, y: barY, width: lw, height: barH), xRadius: barRadius, yRadius: barRadius).fill()
                }
            }
        }

        // 2. Draw text and SF Symbol glyphs per segment
        for i in segments.indices {
            let x = segStarts[i]
            guard x < width else { break }
            let seg = segments[i]
            let foreground = resolveForeground(seg.part.style)
            if let sym = seg.symbolImage {
                let symSize = sym.size
                let drawX = x + seg.leftPad + (seg.contentWidth - symSize.width) / 2.0
                let drawY = 9.0 - symSize.height / 2.0
                drawTintedSymbol(sym, in: NSRect(x: drawX, y: drawY, width: symSize.width, height: symSize.height), color: foreground)
            } else if !seg.displayText.isEmpty {
                let drawY = round((9.0 - seg.font.capHeight / 2.0 + seg.font.descender) * 2.0) / 2.0
                let attrs: [NSAttributedString.Key: Any] = [.font: seg.font, .foregroundColor: foreground]
                (seg.displayText as NSString).draw(at: NSPoint(x: x + seg.leftPad, y: drawY), withAttributes: attrs)
            }
        }
        return true
    }
    image.isTemplate = false
    return StatusRenderOutput(image: image, workspaceRegions: workspaceRegions)
}

/// A vector menu item. Colours, backgrounds, boxes and fonts come from the formatted string; macOS controls its placement alongside menu extras.
func configuredStatusImage(parts: [StatusPart], dark: Bool, showIcon: Bool = true, hoveredWorkspace: Int? = nil) -> NSImage {
    renderConfiguredStatus(parts: parts, dark: dark, showIcon: showIcon, hoveredWorkspace: hoveredWorkspace).image
}
