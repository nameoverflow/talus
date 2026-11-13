import Foundation
@main struct StatusCommandTests {
 static func main() throws {
    let runner = StatusCommands()
    let echo = StatusCommand(name:"echo", executable:"/bin/echo", arguments:["custom status"], interval:10, timeout:2)
    try echo.validate()
    precondition(runner.value(index:0,block:echo) == "")
    let deadline = Date().addingTimeInterval(4)
    while runner.isRunning(index:0) && Date() < deadline { _ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.05)) }
    precondition(!runner.isRunning(index:0) && runner.value(index:0,block:echo) == "custom status")
    let slow = StatusCommand(name:"slow", executable:"/bin/sleep", arguments:["3"], interval:10, timeout:0.2)
    try slow.validate(); _ = runner.value(index:1,block:slow)
    let timeout = Date().addingTimeInterval(3)
    while runner.isRunning(index:1) && Date() < timeout { _ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.05)) }
    precondition(!runner.isRunning(index:1) && runner.value(index:1,block:slow) == "")
    let flood = StatusCommand(name:"flood", executable:"/usr/bin/yes", arguments:["x"], interval:60, timeout:0.2)
    _ = runner.value(index:3,block:flood)
    let floodDeadline = Date().addingTimeInterval(3)
    while runner.isRunning(index:3) && Date() < floodDeadline { _ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.05)) }
    precondition(!runner.isRunning(index:3) && runner.value(index:3,block:flood) == "")
    let context = StatusCommand(name:"context", executable:"/usr/bin/printenv", arguments:["TALUS_STATUS_JSON"], interval:60, timeout:2, onChange:true)
    runner.stateJSON = "first"; _ = runner.value(index:2,block:context)
    let firstDeadline = Date().addingTimeInterval(3)
    while runner.isRunning(index:2) && Date() < firstDeadline { _ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.05)) }
    precondition(runner.value(index:2,block:context) == "first")
    runner.stateJSON = "second"; runner.stateChanged([echo,slow,context]); _ = runner.value(index:2,block:context)
    let secondDeadline = Date().addingTimeInterval(3)
    while runner.isRunning(index:2) && Date() < secondDeadline { _ = RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.05)) }
    precondition(runner.value(index:2,block:context) == "second")
    runner.stopAll()
    print("Asynchronous status command and timeout tests passed")
 }
}
