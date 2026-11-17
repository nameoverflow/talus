import Foundation

struct Rect: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

func insetArea(_ area: Rect, outerGap: Double) -> Rect {
    let cArea = CTalusRect(x: area.x, y: area.y, w: area.w, h: area.h)
    let r = talus_inset_area(cArea, outerGap)
    return Rect(x: r.x, y: r.y, w: r.w, h: r.h)
}

func tallLayout(
    _ area: Rect,
    _ count: Int,
    _ masters: Int,
    _ ratio: Double,
    outerGap: Double = 0,
    innerGap: Double = 0
) -> [Rect]? {
    guard count > 0 else { return [] }
    let cArea = CTalusRect(x: area.x, y: area.y, w: area.w, h: area.h)
    var out = Array(repeating: CTalusRect(x: 0, y: 0, w: 0, h: 0), count: count)
    let n = out.withUnsafeMutableBufferPointer { buf in
        talus_tall_layout_with_gaps(cArea, count, max(0, masters), ratio, outerGap, innerGap, buf.baseAddress)
    }
    return out.prefix(n).map { Rect(x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
}

func mirrorTallLayout(
    _ area: Rect,
    _ count: Int,
    _ masters: Int,
    _ ratio: Double,
    outerGap: Double = 0,
    innerGap: Double = 0
) -> [Rect]? {
    guard count > 0 else { return [] }
    let cArea = CTalusRect(x: area.x, y: area.y, w: area.w, h: area.h)
    var out = Array(repeating: CTalusRect(x: 0, y: 0, w: 0, h: 0), count: count)
    let n = out.withUnsafeMutableBufferPointer { buf in
        talus_mirror_tall_layout_with_gaps(cArea, count, max(0, masters), ratio, outerGap, innerGap, buf.baseAddress)
    }
    return out.prefix(n).map { Rect(x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
}
