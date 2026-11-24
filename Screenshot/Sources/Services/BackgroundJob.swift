import Foundation

/// 将可取消的后台工作与调用方 Task 绑定，排队时取消也能及时恢复等待。
nonisolated final class BackgroundJob<Value: Sendable>: Operation, @unchecked Sendable {
    private let work: @Sendable (Operation) throws -> Value
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?

    init(work: @escaping @Sendable () throws -> Value) {
        self.work = { _ in try work() }
        super.init()
    }

    init(cancellableWork: @escaping @Sendable (Operation) throws -> Value) {
        self.work = cancellableWork
        super.init()
    }

    override func main() {
        guard !isCancelled else { return }
        finish(Result { try work(self) })
    }

    override func cancel() {
        super.cancel()
        finish(.failure(CancellationError()))
    }

    func value(on queue: OperationQueue) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                    queue.addOperation(self)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
