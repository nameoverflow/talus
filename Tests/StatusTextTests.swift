import Foundation
@main struct StatusTextTests {
 static func main() {
    let spaces = [SpaceEntry(id:1,isCurrent:false,isFullscreen:false), SpaceEntry(id:2,isCurrent:true,isFullscreen:false), SpaceEntry(id:3,isCurrent:false,isFullscreen:true)]
    let values = StatusValues(spaces:spaces,layout:"Tall",title:"Editor\nfile",count:3,custom:"CPU 2%",paused:false)
    precondition(renderStatus("{spaces} | {layout} | {title} | {count} | {custom}",values) == "1 [2] 3• | Tall | Editor file | 3 | CPU 2%")
    let literal = StatusValues(spaces:nil,layout:"Tall",title:"{custom}",count:0,custom:"secret",paused:false)
    precondition(renderStatus("{title}", literal) == "{custom}")
    let absent = StatusValues(spaces:nil,layout:"Tall",title:"",count:0,custom:"",paused:true)
    precondition(renderStatus("{spaces} {layout}",absent) == "? Paused")
    let parsed = NativeSpaces.parse(["Current Space":["ManagedSpaceID":2],"Spaces":[["ManagedSpaceID":1,"type":0],["ManagedSpaceID":2,"type":4]]])
    precondition(parsed == [SpaceEntry(id:1,isCurrent:false,isFullscreen:false),SpaceEntry(id:2,isCurrent:true,isFullscreen:true)])
    precondition(NativeSpaces.parse(["Spaces":[]]) == nil)
    print("Status rendering and native Space parsing tests passed")
 }
}
