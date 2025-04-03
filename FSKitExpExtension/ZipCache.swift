import Compression
import FSKit
import Foundation

typealias PathSegment = String

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

// Typealias for zip information
typealias ZipPathInfo = (zipPath: String, subpath: String)

// Define the DependencyNode enum
enum DependencyNode: Decodable {
    case softLink(target: String)
    case zip(zipInfo: ZipPathInfo, children: [PathSegment: DependencyNode])
    case dirPortal(target: String, children: [PathSegment: DependencyNode])

    // Implement Decodable protocol
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let linkType = try container.decode(LinkType.self, forKey: .linkType)
        let target = try container.decodeIfPresent(String.self, forKey: .target)

        switch linkType {
        case .SOFT:
            guard let targetPath = target else {
                throw MyError.badManifest("Soft link requires a target")
            }
            self = .softLink(target: targetPath)

        case .HARD:
            guard let targetPath = target else {
                throw MyError.badManifest("Hard link requires a target")
            }
            let children = try container.decode(
                [PathSegment: DependencyNode].self, forKey: .children)

            // Validate children paths
            for (key, _) in children {
                guard !key.contains("/") && !key.contains(".") else {
                    throw MyError.badManifest("PathSegment cannot contain '/' or '.'")
                }
            }

            // Check if the target has a .zip extension
            if let zipRange = targetPath.range(of: ".zip") {
                let zipPath = String(targetPath[..<zipRange.upperBound])
                var subpath = String(targetPath[zipRange.upperBound...])
                if subpath.isEmpty {
                    subpath = "/"
                }
                self = .zip(zipInfo: (zipPath: zipPath, subpath: subpath), children: children)
            } else {
                self = .dirPortal(target: targetPath, children: children)
            }
        }
    }

    // Deserialize from JSON data
    static func fromJSONData(_ data: Data) throws -> DependencyNode {
        let decoder = JSONDecoder()
        return try decoder.decode(DependencyNode.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case children
        case linkType
        case target
    }
}

protocol FSItemProtocol: FSItem {
    func getChildren() throws -> [(FSFileName, FSItemProtocol)]

    func getChild(name: FSFileName) throws -> FSItemProtocol?

    func getAttributes() throws -> FSItem.Attributes

    func readData(offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) throws -> Int

    func readSymbolicLink() throws -> FSFileName
}

extension FSItem.Identifier {
    @inline(__always)
    static func create(val: UInt64) -> FSItem.Identifier {
        return FSItem.Identifier(rawValue: val)!
    }
    @inline(__always)
    func advance(by: UInt64) -> FSItem.Identifier {
        return FSItem.Identifier.create(val: self.rawValue + by)
    }
    @inline(__always)
    func advance(by: Int) -> FSItem.Identifier {
        return advance(by: UInt64(by))
    }
}

private let uid = getuid()
private let gid = getgid()

final class ZipFSNode: FSItem, FSItemProtocol {
    private let cachedZip: CachedZip
    private let zipId: ZipID
    private let parentId: FSItem.Identifier
    // private var zipEntry: ZipEntry
    init(cachedZip: CachedZip, zipId: ZipID, parentId: FSItem.Identifier) {
        self.cachedZip = cachedZip
        self.zipId = zipId
        self.parentId = parentId
    }
    func getChildren() throws -> [(FSFileName, FSItemProtocol)] {
        let zip = try cachedZip.get()
        let zipEntries = zip.getChildren(forId: zipId)
        return zipEntries.map {
            (
                FSFileName(string: $0.key),
                ZipFSNode(cachedZip: cachedZip, zipId: $0.value, parentId: getFsId())
            )
        }
    }
    func getChild(name: FSFileName) throws -> FSItemProtocol? {
        let zip = try cachedZip.get()
        let zipEntries = zip.getChildren(forId: zipId)
        guard let name = name.string else {  //todo replace all with bytes??
            return nil
        }
        if let zipEntry = zipEntries[name] {
            return ZipFSNode(cachedZip: cachedZip, zipId: zipEntry, parentId: parentId)
        }
        return nil
    }

    func getFsId() -> FSItem.Identifier {
        switch zipId {
        case .dir(let listingId):
            return parentId.advance(by: listingId)
        case .file(let entryInd):
            return parentId.advance(by: 10000 + entryInd)  //todo
        }
    }

    func readSymbolicLink() throws -> FSFileName {
        let listableZip = try self.cachedZip.get()
        guard case .file(let entryInd) = zipId else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        let zipEntry = listableZip.getEntry(index: entryInd)
        guard zipEntry.isSymbolicLink else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        return FSFileName(string: zipEntry.name)
    }

    func readData(offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) throws -> Int {
        switch zipId {
        case .file(let entryInd):
            let listableZip = try self.cachedZip.get()
            let zipEntry = listableZip.getEntry(index: entryInd)
            switch zipEntry.compressionMethod {
            case .deflate:
                throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)  //todo
            // compression_decode_buffer(UnsafeMutablePointer<UInt8>, Int, UnsafePointer<UInt8>, Int, UnsafeMutableRawPointer?, compression_algorithm)

            case .store:
                return try buffer.withUnsafeMutableBytes { rawBuffer in
                    // let buffer = rawBuffer.bindMemory(to: UInt8.self)
                    let bytesRead = try listableZip.readData(
                        index: entryInd,
                        offset: Int(offset),
                        length: length,
                        bufferPointer: rawBuffer,
                    )
                    if bytesRead > 0 {  //todo
                        return bytesRead
                    } else {
                        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
                    }
                }
            }
        case .dir(_):
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
    }

    func getAttributes() throws -> FSItem.Attributes {
        let attr = FSItem.Attributes()
        attr.parentID = parentId
        attr.fileID = getFsId()
        switch zipId {
        case .dir(_):
            attr.size = 0
            attr.allocSize = 0
            attr.linkCount = 1
            attr.type = .directory
            attr.mode = UInt32(S_IFDIR | 0o755)  //by default node_modules created with 755
        case .file(let entryInd):
            let listableZip = try self.cachedZip.get()
            let zipEntry = listableZip.getEntry(index: entryInd)
            attr.linkCount = cachedZip.refCount
            attr.size = UInt64(zipEntry.size)
            attr.allocSize = UInt64(zipEntry.compressedSize)  //todo not sure
            if zipEntry.isSymbolicLink {
                attr.type = .symlink
                attr.mode = UInt32(S_IFLNK | 0o644)  //todo get original, because there are executable
            } else {
                attr.type = .file
                attr.mode = UInt32(S_IFREG | 0o644)  // todo get original, because there are executable
            }
        }

        attr.uid = uid
        attr.gid = gid
        return attr
    }
}

typealias ZipInfo = (cachedZip: CachedZip, subpath: String)

class BaseDependencyFSNode: FSItem {
    internal let dependencyNode: DependencyNode
    internal let fileId: FSItem.Identifier
    internal let parentId: FSItem.Identifier
    internal var children = [PathSegment: BaseDependencyFSNode2]()

    init(dependencyNode: DependencyNode, fileId: FSItem.Identifier, parentId: FSItem.Identifier) {
        self.dependencyNode = dependencyNode
        self.fileId = fileId
        self.parentId = parentId
    }

    static func create(
        dependencyNode: DependencyNode, fileId: FSItem.Identifier, parentId: FSItem.Identifier
    ) -> BaseDependencyFSNode2 {
        switch dependencyNode {
        case .softLink(_):
            let node = SoftDependencyFSNode(
                dependencyNode: dependencyNode, fileId: fileId, parentId: parentId)
            return node
        case .zip(_, _):
            let node = HardDependencyFSNode(
                dependencyNode: dependencyNode, fileId: fileId, parentId: parentId)
            return node
        case .dirPortal(_, _):
            let node = HardDependencyFSNode(
                dependencyNode: dependencyNode, fileId: fileId, parentId: parentId)
            return node
        }
    }

    private static let IdStep = UInt64(10 ^ 7)  // 10 millions files per zip archive.
    static func buildTree(from node: DependencyNode) -> BaseDependencyFSNode {
        var zipCache = [PathSegment: CachedZip]()
        var prevId = FSItem.Identifier.create(val: IdStep)

        let root = BaseDependencyFSNode.create(
            dependencyNode: node, fileId: .rootDirectory, parentId: .parentOfRoot)
        var toVisit = [root]
        while !toVisit.isEmpty {
            let currentNode = toVisit.removeFirst()
            switch currentNode.dependencyNode {
            case .softLink(_):
                break
            case .zip(let zipInfo, _):
                if let cachedZip = zipCache[zipInfo.zipPath] {
                    currentNode.zipInfo = (cachedZip, zipInfo.subpath)
                    cachedZip.refCount += 1
                } else {
                    let cachedZip: CachedZip = CachedZip(zipPath: zipInfo.zipPath)
                    zipCache[zipInfo.zipPath] = cachedZip
                    currentNode.zipInfo = (cachedZip, zipInfo.subpath)
                }
            case .dirPortal(_, _):
                break
            }
            for (name, childNode) in currentNode.dependencyNode.children {
                let child = BaseDependencyFSNode.create(
                    dependencyNode: childNode, fileId: prevId, parentId: currentNode.fileId)
                prevId = prevId.advance(by: IdStep)  //todo reuse id for same zip
                currentNode.children[name] = child
                toVisit.append(child)
            }
        }
        return root
    }
}

typealias BaseDependencyFSNode2 = BaseDependencyFSNode & FSItemProtocol

final class SoftDependencyFSNode: BaseDependencyFSNode, FSItemProtocol {
    func getChildren() throws -> [(FSFileName, FSItemProtocol)] {
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)  //not supported for symlinks
    }

    func getChild(name: FSFileName) throws -> FSItemProtocol? {
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)  //not supported for symlinks
    }

    func getAttributes() throws -> FSItem.Attributes {
        let attr = FSItem.Attributes()
        attr.parentID = parentId
        attr.fileID = fileId
        attr.size = 0
        attr.allocSize = 0
        attr.linkCount = 1
        attr.type = .symlink
        attr.mode = UInt32(S_IFLNK | 0o644)  //todo get original, because there are executable
        return attr
    }

    func readData(offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) throws -> Int {
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)  //not supported for symlinks
    }
    func readSymbolicLink() throws -> FSFileName {
        guard case .softLink(let target) = dependencyNode else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        return FSFileName(string: target)
    }
}

final class HardDependencyFSNode: BaseDependencyFSNode, FSItemProtocol {

    private var zipInfo: ZipInfo? = nil
    private var cachedRootId: ZipID?

    private var cachedZip: CachedZip? {
        return zipInfo?.cachedZip
    }

    private func getRootId(listableZip: ListableZip) throws -> ZipID {
        let rootId =
            try cachedRootId
            ?? {
                let rootId = try listableZip.getIdForPath(path: zipInfo!.subpath)
                cachedRootId = rootId  // todo mutex?
                return rootId
            }()
        return rootId
    }

    private func getZipChildren() throws -> [PathSegment: ZipID]? {
        guard let cachedZip = cachedZip else {
            return nil
        }
        let listableZip = try cachedZip.get()
        return listableZip.getChildren(forId: try getRootId(listableZip: listableZip))
    }

    func getChildren() throws -> [(FSFileName, FSItemProtocol)] {
        var children: [(FSFileName, FSItemProtocol)] = children.map {
            (FSFileName(string: $0.key), $0.value)
        }

        if let zipChildren = try getZipChildren() {
            children += zipChildren.map {
                (
                    FSFileName(string: $0.key),
                    ZipFSNode(cachedZip: cachedZip!, zipId: $0.value, parentId: fileId)
                )
            }
        }
        return children
    }

    func readData(offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) throws -> Int {
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)  //not supported for dirs
    }

    func getChild(name: FSFileName) throws -> FSItemProtocol? {
        guard let name = name.string else {
            return nil
        }
        if let child = children[name] {
            return child
        }
        if let zipChildren = try getZipChildren() {
            if let zipEntry = zipChildren[name] {
                return ZipFSNode(cachedZip: cachedZip!, zipId: zipEntry, parentId: fileId)
            }
        }

        return nil
    }

    func getAttributes() -> FSItem.Attributes {
        let attr = FSItem.Attributes()
        attr.parentID = parentId
        attr.fileID = fileId
        attr.size = 0
        attr.allocSize = 0
        attr.uid = uid
        attr.gid = gid
        attr.type = .directory
        attr.mode = UInt32(S_IFDIR | 0o755)  //by default node_modules created with 755
        return attr
    }

    func readSymbolicLink() throws -> FSFileName {
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)  //not supported for dirs
    }
}

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
