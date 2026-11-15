import Foundation

private final class CallbackBox {
    weak var owner: StatusCommands?
    init(_ owner: StatusCommands) { self.owner = owner }
}

private let statusCommandsCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { rawPtr in
    guard let rawPtr else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(rawPtr).takeUnretainedValue()
    DispatchQueue.main.async {
        box.owner?.onChange?()
    }
}

/// Thin Swift wrapper around `StatusCommandsEngine` in `talus-core`.
final class StatusCommands {
    private var handle: OpaquePointer?
    private var callbackBox: UnsafeMutableRawPointer?
    let stateFile: String?
    var onChange: (() -> Void)?

    var stateJSON: String? {
        get {
            guard let handle, let ptr = talus_status_commands_get_state_json(handle) else { return nil }
            defer { talus_string_free(ptr) }
            return String(cString: ptr)
        }
        set {
            guard let handle else { return }
            if let newValue {
                newValue.withCString { cStr in
                    talus_status_commands_set_state_json(handle, cStr)
                }
            } else {
                talus_status_commands_set_state_json(handle, nil)
            }
        }
    }

    init(stateFile: String? = nil) {
        self.stateFile = stateFile
        let box = CallbackBox(self)
        let retained = Unmanaged.passRetained(box).toOpaque()
        self.callbackBox = retained
        if let stateFile {
            self.handle = stateFile.withCString { cFile in
                talus_status_commands_new(cFile, statusCommandsCallback, retained)
            }
        } else {
            self.handle = talus_status_commands_new(nil, statusCommandsCallback, retained)
        }
    }

    deinit {
        if let handle {
            talus_status_commands_free(handle)
        }
        if let callbackBox {
            Unmanaged<CallbackBox>.fromOpaque(callbackBox).release()
        }
    }

    func value(index: Int, block: StatusCommand) -> String {
        guard let handle,
              let data = try? JSONEncoder().encode(block),
              let jsonStr = String(data: data, encoding: .utf8)
        else { return "" }
        let resPtr = jsonStr.withCString { cJson in
            talus_status_commands_value(handle, max(0, index), cJson)
        }
        defer { if let resPtr { talus_string_free(resPtr) } }
        return resPtr.map { String(cString: $0) } ?? ""
    }

    func stateChanged(_ commands: [StatusCommand]) {
        guard let handle,
              let data = try? JSONEncoder().encode(commands),
              let jsonStr = String(data: data, encoding: .utf8)
        else { return }
        jsonStr.withCString { cJson in
            talus_status_commands_state_changed(handle, cJson)
        }
    }

    func isRunning(index: Int) -> Bool {
        guard let handle else { return false }
        return talus_status_commands_is_running(handle, max(0, index))
    }

    func stopAll() {
        onChange = nil
        if let handle {
            talus_status_commands_stop_all(handle)
        }
    }
}
