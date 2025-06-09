import Foundation
import Synchronization

let maxAge = TimeInterval(30)

typealias CachedZip = Cached<PublicZip>

final class Cached<T>: @unchecked Sendable {
    private var rwlock: pthread_rwlock_t = pthread_rwlock_t()
    var refCount: UInt32
    private enum ZipState {
        case notLoaded
        case loaded(T)
        case error(Error)
    }
    let lastUsedTime = Atomic<TimeInterval>(0)
    private var state: ZipState = .notLoaded
    private let getZip: () throws -> T

    init(_ getZip: @escaping () throws -> T) {
        refCount = 1 // todo not used
        pthread_rwlock_init(&rwlock, nil)
        self.getZip = getZip
    }

    deinit {
        pthread_rwlock_destroy(&rwlock)
    }

    private func clear() {
        pthread_rwlock_wrlock(&rwlock)
        self.state = .notLoaded  // todo check errored
        pthread_rwlock_unlock(&rwlock)
    }

    func cleanIfNeeded() {
        let now = Date().timeIntervalSince1970
        let lastUsed = lastUsedTime.load(ordering: .relaxed)
        if now - lastUsed > maxAge {
            clear()
        }
    }

    func get() throws -> T { //todo async
        lastUsedTime.store(Date().timeIntervalSince1970, ordering: .relaxed)
        pthread_rwlock_rdlock(&rwlock)

        switch state {
        case .loaded(let zip):
            pthread_rwlock_unlock(&rwlock)
            return zip
        case .error(let error):
            pthread_rwlock_unlock(&rwlock)
            throw error
        case .notLoaded:
            pthread_rwlock_unlock(&rwlock)

            // Upgrade to write lock to load the zip
            pthread_rwlock_wrlock(&rwlock)

            // Check state again after acquiring write lock
            switch state {
            case .loaded(let zip):
                pthread_rwlock_unlock(&rwlock)
                return zip
            case .error(let error):
                pthread_rwlock_unlock(&rwlock)
                throw error
            case .notLoaded:
                do {
                    let newZip = try getZip()
                    state = .loaded(newZip)
                    pthread_rwlock_unlock(&rwlock)
                    return newZip
                } catch {
                    state = .error(error)
                    pthread_rwlock_unlock(&rwlock)
                    throw error
                }
            }
        }
    }
}
