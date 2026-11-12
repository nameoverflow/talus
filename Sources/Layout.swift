import Foundation

struct Rect { var x: Double; var y: Double; var w: Double; var h: Double }
func tallLayout(_ area: Rect, _ count: Int, _ masters: Int, _ ratio: Double) -> [Rect]? {
    guard count > 0 else { return [] }
    func split(_ rect: Rect, _ n: Int) -> [Rect] {
        guard n > 1 else { return [rect] }
        let h = floor(rect.h / Double(n))
        return [Rect(x: rect.x, y: rect.y, w: rect.w, h: h)] + split(Rect(x: rect.x, y: rect.y + h, w: rect.w, h: rect.h - h), n - 1)
    }
    if count <= masters || masters == 0 { return split(area, count) }
    let w = floor(area.w * ratio)
    return split(Rect(x: area.x, y: area.y, w: w, h: area.h), masters) + split(Rect(x: area.x + w, y: area.y, w: area.w - w, h: area.h), count - masters)
}
