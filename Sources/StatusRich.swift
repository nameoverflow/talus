import AppKit

struct StatusPart: Equatable {
    let text: String
    let style: StatusSegmentStyle?
    let isCurrent: Bool
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

/// A vector menu item. Colours, backgrounds and fonts come from the formatted string; macOS controls its placement alongside menu extras.
func configuredStatusImage(parts: [StatusPart], dark: Bool, showIcon: Bool = true) -> NSImage {
    let fonts = parts.map { part -> NSFont in
        let size = CGFloat(part.style?.fontSize ?? 11.5)
        return part.style?.font.flatMap { NSFont(name:$0,size:size) } ?? NSFont.monospacedDigitSystemFont(ofSize:size,weight:.medium)
    }
    let metrics = zip(parts,fonts).map { part, font in
        ceil((part.text as NSString).size(withAttributes:[.font:font]).width)
    }
    let leading: CGFloat = showIcon ? 20 : 0
    let width = max(1,min(400,ceil(leading + metrics.reduce(0,+))))
    let image = NSImage(size:NSSize(width:width,height:18),flipped:false) { _ in
        let defaultInk = dark ? NSColor.white : NSColor(calibratedWhite:0.08,alpha:1)
        defaultInk.setFill()
        func tile(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            NSBezierPath(roundedRect:NSRect(x:x,y:y,width:w,height:h),xRadius:1.2,yRadius:1.2).fill()
        }
        if showIcon { tile(1.5,2,7.75,14); tile(10.5,9.625,6,6.375); tile(10.5,2,6,6.375) }
        var x: CGFloat = leading
        for index in parts.indices {
            guard x < width else { break }
            let part = parts[index], style = part.style, w = metrics[index]
            let background = statusColor(style?.background)
            let defaultAlpha: CGFloat = (style?.dimmed == true) ? 0.36 : 0.88
            let foreground = statusColor(style?.foreground) ?? defaultInk.withAlphaComponent(defaultAlpha)
            if let background {
                background.setFill()
                NSBezierPath(rect:NSRect(x:x,y:1.5,width:w,height:15)).fill()
            }
            let attrs: [NSAttributedString.Key:Any] = [.font:fonts[index],.foregroundColor:foreground]
            (part.text as NSString).draw(at:NSPoint(x:x,y:2),withAttributes:attrs)
            x += w
        }
        return true
    }
    image.isTemplate = false
    return image
}
