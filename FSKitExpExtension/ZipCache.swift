import Foundation



// PortablePath enum to handle paths inside and outside of zip archives
enum PortablePath: Decodable {
    case regular(path: String)
    case zipped(zipPath: String, innerPath: String)
    
    init(from string: String) {
        if let zipRange = string.range(of: ".zip") {
            let zipPath = String(string[..<zipRange.upperBound])
            var innerPath = String(string[zipRange.upperBound...])
            if (innerPath == "") {
                innerPath = "/"
            }
            self = .zipped(zipPath: zipPath, innerPath: innerPath)
        } else {
            self = .regular(path: string)
        }
    }

    
    // Encoding and decoding implementation
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        self.init(from: string)
    }
}

// Define the LinkType enum
enum LinkType: String, Decodable {
    case HARD
    case SOFT
}

// Define the LocationNode structure
struct DependencyNode: Decodable {
    var children: [String: DependencyNode]
    var linkType: LinkType
    var target: PortablePath?
    
    // Deserialize from JSON data
    static func fromJSONData(_ data: Data) throws -> DependencyNode {
        let decoder = JSONDecoder()
        return try decoder.decode(DependencyNode.self, from: data)
    }
}

class CachedZip {
    // Replace POSIX mutex with POSIX read-write mutex
    private var rwlock: pthread_rwlock_t = pthread_rwlock_t()
    var val: ListableZip?
    let zipPath: String
    let subPath: String
    init(zipPath: String, subPath: String) {
        self.zipPath = zipPath
        self.subPath = subPath
        pthread_rwlock_init(&rwlock, nil)
    }
    deinit {
        pthread_rwlock_destroy(&rwlock)
    }
    func get() throws -> ListableZip {
        pthread_rwlock_rdlock(&rwlock)
        if let cached = self.val {
            pthread_rwlock_unlock(&rwlock)
            return cached
        }
        pthread_rwlock_unlock(&rwlock)
        pthread_rwlock_wrlock(&rwlock)
        if let cached = self.val {
            pthread_rwlock_unlock(&rwlock)
            return cached
        }
        self.val = try ListableZip.create(fileURL: URL(fileURLWithPath: zipPath))
        let result = self.val!
        pthread_rwlock_unlock(&rwlock)
        return result
    }
}

class ZipCache {
    let zips = [String: CachedZip]()
}
