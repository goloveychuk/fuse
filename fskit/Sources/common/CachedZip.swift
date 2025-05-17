import Foundation


class CachedZip {
    private var rwlock: pthread_rwlock_t = pthread_rwlock_t()
    var refCount: UInt32
    private enum ZipState {
        case notLoaded
        case loaded(ListableZip)
        case error(Error)
    }
    private var state: ZipState = .notLoaded
    let zipPath: String

    init(zipPath: String) {
        self.zipPath = zipPath
        refCount = 1
        pthread_rwlock_init(&rwlock, nil)
    }

    deinit {
        pthread_rwlock_destroy(&rwlock)
    }

    func clear() {
        pthread_rwlock_wrlock(&rwlock)
        self.state = .notLoaded  // todo check errored
        pthread_rwlock_unlock(&rwlock)
    }

    func get() throws -> ListableZip {
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
                    let newZip = try ListableZip(fileURL: URL(fileURLWithPath: zipPath))
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
