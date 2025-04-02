import Foundation

typealias PathSegment = String

// PortablePath enum to handle paths inside and outside of zip archives
enum PortablePath: Decodable {
    case regular(path: String)
    case zipped(zipPath: String, innerPath: String)

    init(from string: String) {
        if let zipRange = string.range(of: ".zip") {
            let zipPath = String(string[..<zipRange.upperBound])
            var innerPath = String(string[zipRange.upperBound...])
            if innerPath == "" {
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

// Define custom errors for dependency operations
enum MyError: Error {
    case badManifest(String)

    var localizedDescription: String {
        switch self {
        case .badManifest(let err):
            return "Bad manifest: \(err)"
        }
    }
}
// Define the LocationNode structure
struct DependencyNode: Decodable {
    var children: [PathSegment: DependencyNode]
    var linkType: LinkType
    var target: PortablePath?

    // Deserialize from JSON data
    static func fromJSONData(_ data: Data) throws -> DependencyNode {
        let decoder = JSONDecoder()
        let val = try decoder.decode(DependencyNode.self, from: data)
        for (key, _) in val.children {
            guard !key.contains("/") && !key.contains(".") else {
                throw MyError.badManifest("PathSegment cannot contain '/' or '.'")
            }
        }
        return val
    }
}

class DependencyFSNode {
    let dependencyNode: DependencyNode
    var children = [PathSegment: DependencyFSNode]()
    private var cachedZip: CachedZip? = nil
    init(dependencyNode: DependencyNode) {
        self.dependencyNode = dependencyNode
    }

    static func buildTree(from node: DependencyNode) -> DependencyFSNode {
        var zipCache = [PathSegment: CachedZip]()
        let root = DependencyFSNode(dependencyNode: node)
        var toVisit = [root]
        while !toVisit.isEmpty {
            let currentNode = toVisit.removeFirst()
            if let target = currentNode.dependencyNode.target {
                    switch target {
                    case .zipped(let zipPath, _):
                        if let cachedZip = zipCache[zipPath] {
                            currentNode.cachedZip = cachedZip
                        } else {
                            let newCachedZip: CachedZip = CachedZip(zipPath: zipPath)
                            zipCache[zipPath] = newCachedZip
                            currentNode.cachedZip = newCachedZip
                        }
                    case .regular(_):
                        break
                    }
                }
            for (name, childNode) in currentNode.dependencyNode.children {
                let child = DependencyFSNode(dependencyNode: childNode)
                currentNode.children[name] = child
                toVisit.append(child)
            }
        }
        return root
    }
}

class CachedZip {
    // Replace POSIX mutex with POSIX read-write mutex
    private var rwlock: pthread_rwlock_t = pthread_rwlock_t()
    var val: ListableZip?
    let zipPath: String
    init(zipPath: String) {
        self.zipPath = zipPath
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
