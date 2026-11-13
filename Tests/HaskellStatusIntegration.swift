import Foundation
@main struct HaskellStatusIntegration {
 static func main() throws {
    let runner = StatusCommands()
    let command = StatusCommand(name:"clock", executable:CommandLine.arguments[1], arguments:[CommandLine.arguments[2]], interval:60, timeout:10, markup:true)
    try command.validate()
    _ = runner.value(index:0,block:command)
    let deadline = Date().addingTimeInterval(12)
    while runner.isRunning(index:0) && Date() < deadline { _ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.05)) }
    let text = runner.value(index:0,block:command)
    precondition(text.hasPrefix("<fc=#89CFC2>λ ") && text.hasSuffix("</fc>"))
    var config = Configuration(); config.statusTemplate = "%clock%"; config.statusCommands = [command]
    let values = StatusValues(spaces:nil,layout:"Tall",title:"",count:0,custom:"",paused:false)
    let parts = templateStatusParts(config:config,values:values) { _ in text }
    precondition(parts.count == 1 && parts[0].text.hasPrefix("λ ") && parts[0].style?.foreground == "#89CFC2")
    runner.stopAll()
    print("Haskell command output rendered as configured markup")
 }
}
