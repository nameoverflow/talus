import CoreGraphics
@main struct ScreenGeometryTests {
    static func main() {
        let primary = accessibilityFrame(visible: CGRect(x:0,y:25,width:1440,height:852), primaryTop:900)
        precondition(primary == CGRect(x:0,y:23,width:1440,height:852))
        let left = accessibilityFrame(visible: CGRect(x:-1920,y:-100,width:1920,height:1050), primaryTop:900)
        precondition(left == CGRect(x:-1920,y:-50,width:1920,height:1050))
        let above = accessibilityFrame(visible: CGRect(x:300,y:900,width:1600,height:900), primaryTop:900)
        precondition(above == CGRect(x:300,y:-900,width:1600,height:900))
        let below = accessibilityFrame(visible: CGRect(x:0,y:-1080,width:1920,height:1055), primaryTop:900)
        precondition(below == CGRect(x:0,y:925,width:1920,height:1055))
        print("Screen coordinate conversion tests passed")
    }
}
