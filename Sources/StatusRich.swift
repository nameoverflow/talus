import AppKit

struct StatusPart: Equatable {
    let text: String
    let style: StatusSegmentStyle?
    let isCurrent: Bool
    var workspaceIndex: Int? = nil
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
    let textWidth: CGFloat
    let leftPad: CGFloat
    let rightPad: CGFloat
    var totalWidth: CGFloat { textWidth + leftPad + rightPad }
}

/// Renders the menu bar item as a crisp vector image and returns clickable workspace hit regions.
func renderConfiguredStatus(
    parts: [StatusPart],
    dark: Bool,
    showIcon: Bool = true,
    hoveredWorkspace: Int? = nil
) -> StatusRenderOutput {
    let segments: [SegmentMetrics] = parts.map { part in
        let size = CGFloat(part.style?.fontSize ?? 11.5)
        let font = part.style?.font.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.monospacedDigitSystemFont(ofSize: size, weight: part.isCurrent ? .semibold : .medium)
        let textW = ceil((part.text as NSString).size(withAttributes: [.font: font]).width)
        let hasChrome = (part.style?.background != nil || part.style?.box?.type == .full)
            && !part.text.trimmingCharacters(in: .whitespaces).isEmpty
        var leftPad: CGFloat = 0
        var rightPad: CGFloat = 0
        if hasChrome {
            leftPad = part.text.hasPrefix(" ") ? 2.5 : 6.0
            rightPad = part.text.hasSuffix(" ") ? 2.5 : 6.0
        }
        return SegmentMetrics(part: part, font: font, textWidth: textW, leftPad: leftPad, rightPad: rightPad)
    }

    let leading: CGFloat = showIcon ? 22 : 0
    let rawWidth = leading + segments.reduce(0) { $0 + $1.totalWidth }
    let width = max(1, min(460, ceil(rawWidth)))

    var workspaceRegions: [StatusWorkspaceHitRegion] = []
    var cursorX: CGFloat = leading
    for seg in segments {
        guard cursorX < width else { break }
        let segW = min(seg.totalWidth, width - cursorX)
        if let wsIdx = seg.part.workspaceIndex {
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

        var x: CGFloat = leading
        for seg in segments {
            guard x < width else { break }
            let part = seg.part, style = part.style
            let segW = seg.totalWidth
            let pillRect = NSRect(x: x, y: 1, width: segW, height: 16)
            let pillRadius = min(pillRect.height / 2, CGFloat(style?.box?.radius ?? 8.0))

            let background = statusColor(style?.background)
            let defaultAlpha: CGFloat = (style?.dimmed == true) ? (dark ? 0.54 : 0.48) : 0.92
            var foreground = statusColor(style?.foreground) ?? defaultInk.withAlphaComponent(defaultAlpha)
            if style?.dimmed == true && style?.foreground != nil {
                foreground = foreground.withAlphaComponent(foreground.alphaComponent * 0.62)
            }

            if let background {
                background.setFill()
                NSBezierPath(roundedRect: pillRect, xRadius: pillRadius, yRadius: pillRadius).fill()
                if let hoveredWorkspace, part.workspaceIndex == hoveredWorkspace {
                    let gloss = dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.white.withAlphaComponent(0.22)
                    gloss.setFill()
                    NSBezierPath(roundedRect: pillRect, xRadius: pillRadius, yRadius: pillRadius).fill()
                }
            }

            if let box = style?.box {
                let boxColor = statusColor(box.color) ?? foreground
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
                    let barInset = min(3.5, segW * 0.14)
                    let barW = max(2, segW - barInset * 2)
                    let barX = x + barInset
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
                    NSBezierPath(roundedRect: NSRect(x: x + 0.5, y: barY, width: lw, height: barH), xRadius: barRadius, yRadius: barRadius).fill()
                    NSBezierPath(roundedRect: NSRect(x: x + segW - lw - 0.5, y: barY, width: lw, height: barH), xRadius: barRadius, yRadius: barRadius).fill()
                }
            }

            let drawY = round((9.0 - seg.font.capHeight / 2.0 + seg.font.descender) * 2.0) / 2.0
            let attrs: [NSAttributedString.Key: Any] = [.font: seg.font, .foregroundColor: foreground]
            (part.text as NSString).draw(at: NSPoint(x: x + seg.leftPad, y: drawY), withAttributes: attrs)
            x += segW
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
