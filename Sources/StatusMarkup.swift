import Foundation

private func markupColor(_ value: String) -> String? {
    let named = ["black":"#000000","white":"#FFFFFF","red":"#FF5555","green":"#50FA7B",
                 "blue":"#6272A4","yellow":"#F1FA8C","cyan":"#8BE9FD","magenta":"#FF79C6"]
    if let result = named[value.lowercased()] { return result }
    return value.range(of:"^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$",options:.regularExpression) == nil ? nil : value
}

private func parseBoxTag(_ tag: String) -> StatusBoxStyle? {
    let body = tag.dropFirst(3).trimmingCharacters(in: .whitespaces)
    var box = StatusBoxStyle()
    if body.isEmpty { return box }
    for token in body.split(separator: " ", omittingEmptySubsequences: true) {
        let kv = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard kv.count == 2 else { return nil }
        let key = kv[0].lowercased()
        let val = String(kv[1])
        switch key {
        case "type":
            switch val.lowercased() {
            case "full": box.type = .full
            case "bottom": box.type = .bottom
            case "top": box.type = .top
            case "hboth": box.type = .hBoth
            case "vboth": box.type = .vBoth
            default: return nil
            }
        case "width":
            guard let w = Double(val), (1...4).contains(w) else { return nil }
            box.width = w
        case "color":
            guard let c = markupColor(val) else { return nil }
            box.color = c
        case "radius":
            guard let r = Double(val), (0...9).contains(r) else { return nil }
            box.radius = r
        default:
            return nil
        }
    }
    return box
}

/// Parses Talus's supported <fc>, <fn>, and <box> formatting tags. Data substituted
/// for a token is emitted literally unless its command explicitly opts in.
func parseStatusMarkup(_ source: String, fonts: [String], fontSize: Double,
                       initial: StatusSegmentStyle? = nil, current: Bool = false,
                       workspaceIndex: Int? = nil,
                       resolve: (String, StatusSegmentStyle?) -> [StatusPart]? = { _,_ in nil }) -> [StatusPart] {
    let text = String(source.prefix(4096))
    var result: [StatusPart] = [], buffer = "", style = initial ?? StatusSegmentStyle()
    var stack: [(String,StatusSegmentStyle)] = [], index = text.startIndex
    style.fontSize = style.fontSize ?? fontSize
    func flush() {
        guard !buffer.isEmpty, result.count < 512 else { buffer = ""; return }
        let clean = String(buffer.replacingOccurrences(of:"[\\r\\n\\t]+",with:" ",options:.regularExpression).prefix(512))
        if !clean.isEmpty { result.append(StatusPart(text:clean,style:style,isCurrent:current,workspaceIndex:workspaceIndex)) }
        buffer = ""
    }
    while index < text.endIndex {
        let tail = text[index...]
        if tail.hasPrefix("</fc>") || tail.hasPrefix("</fn>") || tail.hasPrefix("</box>") {
            let tag = tail.hasPrefix("</fc>") ? "fc" : (tail.hasPrefix("</fn>") ? "fn" : "box")
            let closeLen = tag.count + 3
            if let top = stack.last, top.0 == tag {
                flush(); style = top.1; stack.removeLast(); index = text.index(index,offsetBy:closeLen); continue
            }
        }
        if text[index] == "<", stack.count < 16, let end = tail.firstIndex(of:">"), text.distance(from:index,to:end) <= 100 {
            let tag = String(text[text.index(after:index)..<end])
            if tag.hasPrefix("fc=") {
                let pieces = tag.dropFirst(3).split(separator:",",omittingEmptySubsequences:false).map(String.init)
                let fgValid = (pieces.count == 2 && pieces[0].isEmpty) || markupColor(pieces[0]) != nil
                if (1...2).contains(pieces.count), fgValid,
                   pieces.count == 1 || markupColor(pieces[1]) != nil {
                    flush(); stack.append(("fc",style))
                    if let fg = markupColor(pieces[0]) { style.foreground = fg }
                    if pieces.count == 2 { style.background = markupColor(pieces[1]) }
                    index = text.index(after:end); continue
                }
            } else if tag.hasPrefix("fn="), let fontIndex = Int(tag.dropFirst(3)), fontIndex >= 0 {
                flush(); stack.append(("fn",style)); style.font = fontIndex < fonts.count ? fonts[fontIndex] : nil
                index = text.index(after:end); continue
            } else if tag == "box" || tag.hasPrefix("box "), let box = parseBoxTag(tag) {
                flush(); stack.append(("box",style)); style.box = box
                index = text.index(after:end); continue
            } else if tag.hasPrefix("sf=") {
                let sym = String(tag.dropFirst(3))
                if sym.range(of:"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",options:.regularExpression) != nil {
                    flush()
                    if result.count < 512 {
                        result.append(StatusPart(text:"",style:style,isCurrent:current,workspaceIndex:workspaceIndex,symbolName:sym))
                    }
                    index = text.index(after:end); continue
                }
            }
        }
        if text[index] == "%" {
            let next = text.index(after:index)
            if next < text.endIndex && text[next] == "%" { buffer.append("%"); index = text.index(after:next); continue }
            if next < text.endIndex, let end = text[next...].firstIndex(of:"%"), text.distance(from:next,to:end) <= 32 {
                let token = String(text[next..<end])
                if let substitution = resolve(token,style) {
                    flush(); result.append(contentsOf:substitution.prefix(max(0,512-result.count)))
                    index = text.index(after:end); continue
                }
            }
        }
        buffer.append(text[index]); index = text.index(after:index)
    }
    flush(); return result
}

func templateStatusParts(config: Configuration, values: StatusValues, commandOutput: (Int) -> String = { _ in "" }) -> [StatusPart] {
    let builtins: [String:String] = ["layout":values.paused ? "Paused" : values.layout,
                                    "title":String(values.title.prefix(24)), "count":String(values.count),
                                    "custom":String(values.custom.prefix(48))]
    func literal(_ text: String, _ style: StatusSegmentStyle?, _ current: Bool = false, _ workspaceIndex: Int? = nil) -> [StatusPart] {
        let clean = String(text.replacingOccurrences(of:"[\\r\\n\\t]+",with:" ",options:.regularExpression).prefix(160))
        return clean.isEmpty ? [] : [StatusPart(text:clean,style:style,isCurrent:current,workspaceIndex:workspaceIndex)]
    }
    func workspaces(_ inherited: StatusSegmentStyle?) -> [StatusPart] {
        guard let entries = values.spaces else { return literal("?",inherited) }
        var output: [StatusPart] = []
        for (index, entry) in entries.enumerated() {
            if index > 0 { output += literal(" ",inherited) }
            let label = index < values.spaceLabels.count ? values.spaceLabels[index] : String(index+1)
            let isOccupied = (entry.windowCount ?? 0) > 0
            let fields = [
                "label": label,
                "index": String(index+1),
                "fullscreen": entry.isFullscreen ? "•" : "",
                "occupied": (!entry.isCurrent && isOccupied) ? "•" : "",
            ]
            let workspaceTemplate = entry.isCurrent ? config.workspaceCurrent : config.workspaceOther
            var entryStyle = inherited ?? StatusSegmentStyle()
            if !entry.isCurrent && entry.windowCount == 0 {
                entryStyle.dimmed = true
            }
            output += parseStatusMarkup(workspaceTemplate,fonts:config.statusFonts,fontSize:config.statusFontSize,initial:entryStyle,current:entry.isCurrent,workspaceIndex:index) { token, style in
                if token == "icon" {
                    let iconSpec = index < values.spaceIcons.count ? values.spaceIcons[index] : ""
                    if iconSpec.range(of:"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",options:.regularExpression) != nil {
                        return [StatusPart(text:"",style:style,isCurrent:entry.isCurrent,workspaceIndex:index,symbolName:iconSpec)]
                    }
                    let fallback = iconSpec.isEmpty ? label : iconSpec
                    return literal(fallback,style,entry.isCurrent,index)
                }
                return fields[token].map { literal($0,style,entry.isCurrent,index) }
            }
        }
        return output
    }
    let legacy = config.statusFormat.replacingOccurrences(of:"{spaces}",with:"%spaces%")
        .replacingOccurrences(of:"{layout}",with:"%layout%").replacingOccurrences(of:"{title}",with:"%title%")
        .replacingOccurrences(of:"{count}",with:"%count%").replacingOccurrences(of:"{custom}",with:"%custom%")
    let raw = parseStatusMarkup(config.statusTemplate ?? legacy,fonts:config.statusFonts,fontSize:config.statusFontSize) { token, style in
        if token == "spaces" { return workspaces(style) }
        if let value = builtins[token] { return literal(value,style) }
        if let index = config.statusCommands.firstIndex(where: { $0.name == token }) {
            let text = commandOutput(index)
            if config.statusCommands[index].markup == true {
                return parseStatusMarkup(text,fonts:config.statusFonts,fontSize:config.statusFontSize,initial:style)
            }
            return literal(text,style)
        }
        return nil
    }
    var merged: [StatusPart] = []
    for part in raw {
        if let last = merged.last,
           last.symbolName == nil, part.symbolName == nil,
           last.style == part.style, last.isCurrent == part.isCurrent, last.workspaceIndex == part.workspaceIndex {
            merged[merged.count-1] = StatusPart(text:last.text + part.text,style:last.style,isCurrent:last.isCurrent,workspaceIndex:last.workspaceIndex)
        } else { merged.append(part) }
    }
    return merged
}
