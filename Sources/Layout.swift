import Foundation

struct Rect {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

func tallLayout(_ area: Rect, _ count: Int, _ masters: Int, _ ratio: Double) -> [Rect]? {
    guard count > 0 else { return [] }
    let cArea = CTalusRect(x: area.x, y: area.y, w: area.w, h: area.h)
    var out = Array(repeating: CTalusRect(x: 0, y: 0, w: 0, h: 0), count: count)
    let n = out.withUnsafeMutableBufferPointer { buf in
        talus_tall_layout(cArea, count, max(0, masters), ratio, buf.baseAddress)
    }
    return out.prefix(n).map { Rect(x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
}

func mirrorTallLayout(_ area: Rect, _ count: Int, _ masters: Int, _ ratio: Double) -> [Rect]? {
    guard count > 0 else { return [] }
    let cArea = CTalusRect(x: area.x, y: area.y, w: area.w, h: area.h)
    var out = Array(repeating: CTalusRect(x: 0, y: 0, w: 0, h: 0), count: count)
    let n = out.withUnsafeMutableBufferPointer { buf in
        talus_mirror_tall_layout(cArea, count, max(0, masters), ratio, buf.baseAddress)
    }
    return out.prefix(n).map { Rect(x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
}
