import Foundation
@main struct LayoutProperties {
    static func main() {
        var state: UInt64 = 0x12345678
        func random(_ max: Int) -> Int { state = state &* 6364136223846793005 &+ 1; return Int((state >> 32) % UInt64(max)) }
        for _ in 0..<100_000 {
            let width = 200 + random(3000), height = 200 + random(2000)
            let count = 1 + random(20), masters = 1 + random(8)
            let x = random(4000) - 2000, y = random(2000) - 1000
            let area = Rect(x: Double(x), y: Double(y), w: Double(width), h: Double(height))
            let boxes = tallLayout(area, count, masters, Double(2 + random(7)) / 10)!
            precondition(boxes.count == count)
            precondition(boxes.allSatisfy { $0.x >= area.x && $0.y >= area.y && $0.x + $0.w <= area.x + area.w && $0.y + $0.h <= area.y + area.h })
            precondition(boxes.reduce(0) { $0 + $1.w * $1.h } == area.w * area.h)
            for i in boxes.indices { for j in boxes.indices where j > i {
                let a = boxes[i], b = boxes[j]
                precondition(a.x + a.w <= b.x || b.x + b.w <= a.x || a.y + a.h <= b.y || b.y + b.h <= a.y)
            }}
        }
        print("100,000 randomized layouts passed coverage and overlap checks")
    }
}
