import Foundation
@main struct LayoutTests {
    static func main() {
        let area = Rect(x: -100, y: 20, w: 1000, h: 801)
        let one = tallLayout(area, 1, 1, 0.5)!
        precondition(one.count == 1 && one[0].w == 1000 && one[0].x == -100)
        let three = tallLayout(area, 3, 1, 0.5)!
        precondition(three.count == 3 && three[0].w == 500 && three[1].h == 400 && three[2].h == 401 && three[2].y == 420)
        let multi = tallLayout(area, 4, 2, 0.6)!
        precondition(multi.count == 4 && multi[0].w == 600 && multi[1].h == 401 && multi[2].w == 400)
        let mirror = mirrorTallLayout(area, 3, 1, 0.5)!
        precondition(mirror[0].h == 400 && mirror[0].w == 1000 && mirror[1].x == -100 && mirror[2].x == 400 && mirror[2].y == 420)
        precondition(tallLayout(area, 0, 1, 0.5)!.isEmpty)
        print("Tall layout tests passed")
    }
}
