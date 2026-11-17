import Foundation

/// A burst of requests updates the UI once, outside the input handler.
final class MainLoopUpdate {
    private var pending: DispatchWorkItem?
    private let update: () -> Void

    init(_ update: @escaping () -> Void) { self.update = update }

    func request() {
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.update()
        }
        pending = work
        DispatchQueue.main.async(execute: work)
    }

    func flush() {
        pending?.cancel()
        pending = nil
        update()
    }
}
