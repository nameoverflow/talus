import Foundation
import Darwin

/// Runs explicitly configured executables off the UI thread. It never invokes a
/// shell unless the user explicitly configures one, and bounds output and time.
final class StatusCommands {
    private final class Capture {
        let lock = NSLock()
        var bytes = Data()
        func consume(_ handle: FileHandle) {
            lock.lock(); defer { lock.unlock() }
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let count = min(data.count, max(0,4096-bytes.count))
            if count > 0 { bytes.append(data.prefix(count)) }
        }
        func close(_ handle: FileHandle) {
            lock.lock(); defer { lock.unlock() }
            handle.readabilityHandler = nil
            try? handle.close()
        }
        func text() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding:bytes,as:UTF8.self).trimmingCharacters(in:.newlines)
        }
    }
    private final class State {
        var next = Date.distantPast
        var text = ""
        var process: Process?
        var reader: FileHandle?
        var capture: Capture?
        var timedOut = false
    }
    private var states: [Int:State] = [:]
    private var stopped = false
    let stateFile: String?
    var stateJSON: String?
    init(stateFile: String? = nil) { self.stateFile = stateFile }
    var onChange: (() -> Void)?

    /// Call on the main thread; completed values are returned immediately.
    func value(index: Int, block: StatusCommand) -> String {
        let state = states[index] ?? State(); states[index] = state
        guard !stopped else { return state.text }
        if state.process == nil && Date() >= state.next { start(index:index, block:block, state:state) }
        return state.text
    }
    private func start(index: Int, block: StatusCommand, state: State) {
        let executable = block.executable
        state.next = Date().addingTimeInterval(block.interval ?? 10)
        state.timedOut = false
        let process = Process(); let pipe = Pipe(); let capture = Capture()
        process.executableURL = URL(fileURLWithPath:executable)
        process.arguments = block.arguments ?? []
        var environment = ProcessInfo.processInfo.environment
        if let stateFile, !stateFile.isEmpty { environment["TALUS_STATUS_FILE"] = (stateFile as NSString).expandingTildeInPath }
        if let stateJSON { environment["TALUS_STATUS_JSON"] = stateJSON }
        process.environment = environment
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        state.process = process; state.reader = pipe.fileHandleForReading; state.capture = capture
        pipe.fileHandleForReading.readabilityHandler = { handle in capture.consume(handle) }
        process.terminationHandler = { [weak self, weak state] ended in
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {
                guard let self, let state, state.process === ended else { return }
                if let reader = state.reader { capture.close(reader) }
                state.reader = nil; state.capture = nil
                let text = (!state.timedOut && ended.terminationStatus == 0) ? capture.text() : ""
                let changed = state.text != text
                state.text = text; state.process = nil
                if changed { self.onChange?() }
                let delay = max(0,state.next.timeIntervalSinceNow)
                DispatchQueue.main.asyncAfter(deadline:.now()+delay) { [weak self, weak state] in
                    guard let self, let state, !self.stopped, state.process == nil else { return }
                    self.onChange?()
                }
            }
        }
        do { try process.run(); try? pipe.fileHandleForWriting.close() }
        catch {
            capture.close(pipe.fileHandleForReading); try? pipe.fileHandleForWriting.close()
            state.process = nil; state.reader = nil; state.capture = nil
            if !state.text.isEmpty { state.text = ""; onChange?() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline:.now() + (block.timeout ?? 2)) { [weak state, weak process] in
            guard let state, let process, state.process === process, process.isRunning else { return }
            state.timedOut = true; process.terminate()
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak state, weak process] in
                guard let state, let process, state.process === process, process.isRunning else { return }
                kill(process.processIdentifier,SIGKILL)
            }
        }
    }
    func stateChanged(_ commands: [StatusCommand]) {
        for (index, command) in commands.enumerated() where command.onChange == true { states[index]?.next = .distantPast }
    }
    func isRunning(index: Int) -> Bool { states[index]?.process != nil }
    func stopAll() {
        stopped = true; onChange = nil
        for state in states.values {
            if let process = state.process, process.isRunning { kill(process.processIdentifier,SIGKILL) }
            if let reader = state.reader { state.capture?.close(reader) }
            state.reader = nil; state.capture = nil
        }
    }
}
