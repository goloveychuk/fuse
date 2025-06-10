import Foundation
import Synchronization

let maxAge = TimeInterval(30)

typealias CachedZip = Cached<PublicZip>

actor AsyncMemoize<T: Sendable> {
    private var result: Result<T, Error>?
    private var isLoading = false
    private var continuations = [CheckedContinuation<T, Error>]()
    private let task: () async throws -> T
    
    init(_ task: @escaping () async throws -> T) {
        self.task = task
    }

    func clear() {
        result = nil
    }
    
    func callAsFunction() async throws -> T {
        // Return cached result if available
        if let result = result {
            return try result.get()
        }
        
        // If already loading, wait for completion
        if isLoading {
            return try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
            }
        }
        
        // Start loading
        isLoading = true
        
        do {
            let value = try await task()
            result = .success(value)
            
            // Resume any waiting continuations
            for continuation in continuations {
                continuation.resume(returning: value)
            }
            continuations.removeAll()
            isLoading = false
            
            return value
        } catch {
            result = .failure(error)
            
            // Resume any waiting continuations with error
            for continuation in continuations {
                continuation.resume(throwing: error)
            }
            continuations.removeAll()
            isLoading = false
            
            throw error
        }
    }
}



final class Cached<T: Sendable>: @unchecked Sendable {

    var refCount: UInt32
    let lastUsedTime = Atomic<TimeInterval>(0)
    private let memoized: AsyncMemoize<T>

    init(_ getZip: @escaping @Sendable () async throws -> T) {
        refCount = 1
        self.memoized = AsyncMemoize(getZip)
    }


    func cleanIfNeeded() async {
        let now = Date().timeIntervalSince1970
        let lastUsed = lastUsedTime.load(ordering: .relaxed)
        if now - lastUsed > maxAge {
            await memoized.clear()
        }
    }

    func get() async throws -> T {
        lastUsedTime.store(Date().timeIntervalSince1970, ordering: .relaxed)
        return try await memoized.callAsFunction()
    }
}
