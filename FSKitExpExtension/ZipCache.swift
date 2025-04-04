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

typealias Children = [PathSegment: DependencyNode]

typealias SoftLinkData = String
// Define the DependencyNode enum
enum DependencyNode: Decodable {
    case softLink(data: SoftLinkData)
    case zip(zipInfo: ZipPathInfo, children: Children)
    case dirPortal(target: String, children: Children)

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
            self = .softLink(data: targetPath)

        case .HARD:
            guard let targetPath = target else {
                throw MyError.badManifest("Hard link requires a target")
            }
            let children = try container.decode(
                Children.self, forKey: .children)

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
    var fileId: FSItem.Identifier { get }
    var itemType: FSItem.ItemType { get }

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
    let fileId: FSItem.Identifier

    var itemType: FSItem.ItemType {
        switch zipId {
        case .symlink(_):
            return .symlink
        case .dir:
            return .directory
        case .file(_):            
            return .file
        }
    }
    // private var zipEntry: ZipEntry
    init(cachedZip: CachedZip, zipId: ZipID, parentId: FSItem.Identifier) {
        self.cachedZip = cachedZip
        self.zipId = zipId
        self.parentId = parentId

        switch zipId {
        case .dir(let listingId):
            self.fileId = parentId.advance(by: listingId)
        case .file(let entryInd), .symlink(let entryInd):
            self.fileId = parentId.advance(by: 10000 + entryInd)  //todo
        }
    }

    func getChildren() throws -> [(FSFileName, FSItemProtocol)] {
        let zip = try cachedZip.get()
        let zipEntries = zip.getChildren(forId: zipId)
        return zipEntries.map {
            (
                FSFileName(string: $0.key),
                ZipFSNode(cachedZip: cachedZip, zipId: $0.value, parentId: fileId)
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

    func readSymbolicLink() throws -> FSFileName {
        let listableZip = try self.cachedZip.get()
        guard case .symlink(let entryInd) = zipId else {
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
        case .symlink(_):
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)

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
        attr.fileID = fileId
        attr.type = itemType
        attr.uid = uid
        attr.gid = gid
        switch zipId {
        case .dir(_):
            attr.size = 0
            attr.allocSize = 0
            attr.linkCount = 1
            attr.type = .directory
            attr.mode = UInt32(S_IFDIR | 0o755)  //by default node_modules created with 755
        case .symlink(_):
            attr.size = 1
            attr.allocSize = 1
            attr.mode = UInt32(S_IFLNK | 0o644)  //todo get original, because there are executable
        case .file(let entryInd):
            let listableZip = try self.cachedZip.get()
            let zipEntry = listableZip.getEntry(index: entryInd)
            attr.linkCount = cachedZip.refCount
            attr.size = UInt64(zipEntry.size)
            attr.allocSize = UInt64(zipEntry.compressedSize)  //todo not sure
            attr.mode = UInt32(S_IFREG | 0o644)  // todo get original, because there are executable
        }
        return attr
    }
}

typealias ZipInfo = (cachedZip: CachedZip, subpath: String)

final class DependencyFSNodeCreator {
    private static let IdStep = UInt64(10 ^ 7)  // 10 millions files per zip archive.

    var zipCache = [PathSegment: CachedZip]()
    var prevId = FSItem.Identifier.create(val: IdStep)

    func create(
        dependencyNode: DependencyNode, fileId: FSItem.Identifier, parentId: FSItem.Identifier
    ) -> FSItemProtocol {
        switch dependencyNode {
        case .softLink(let data):
            let node = SoftDependencyFSNode(
                fileId: fileId, parentId: parentId, data: data)
            return node
        case .zip(let info, let children):
            let zipInfo: ZipInfo
            if let cachedZip = zipCache[info.zipPath] {
                zipInfo = (cachedZip, subpath: info.subpath)
                cachedZip.refCount += 1
            } else {
                let cachedZip: CachedZip = CachedZip(zipPath: info.zipPath)
                zipCache[info.zipPath] = cachedZip
                zipInfo = (cachedZip, subpath: info.subpath)
            }
            let node = ZipHardDependencyFSNode(
                fileId: fileId, parentId: parentId,
                children: createChildren(parentId: fileId, children: children), zipInfo: zipInfo)
            return node

        case .dirPortal(_, let children):  //todo impl
            let node = HardDependencyFSNode(
                fileId: fileId, parentId: parentId,
                children: createChildren(parentId: fileId, children: children))

            return node
        }
    }

    func createChildren(parentId: FSItem.Identifier, children: Children) -> [PathSegment:
        FSItemProtocol]
    {
        return children.mapValues { node in
            let child = create(
                dependencyNode: node, fileId: prevId, parentId: parentId)
            prevId = prevId.advance(by: DependencyFSNodeCreator.IdStep)  //todo reuse id for same zip
            return child
        }
    }

    func buildTree(from node: DependencyNode) -> FSItemProtocol {
        return create(
            dependencyNode: node, fileId: .rootDirectory, parentId: .parentOfRoot)
    }
}

// typealias BaseDependencyFSNode2 = BaseDependencyFSNode & FSItemProtocol

final class SoftDependencyFSNode: FSItem, FSItemProtocol {
    private let data: SoftLinkData
    let itemType: FSItem.ItemType = .symlink
    private let parentId: FSItem.Identifier
    let fileId: FSItem.Identifier

    init(fileId: FSItem.Identifier, parentId: FSItem.Identifier, data: SoftLinkData) {
        self.data = data
        self.fileId = fileId
        self.parentId = parentId
    }

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
        attr.size = 1
        attr.allocSize = 1
        attr.linkCount = 1
        attr.type = itemType
        attr.mode = UInt32(S_IFLNK | 0o644)  //todo get original, because there are executable
        return attr
    }

    func readData(offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) throws -> Int {
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)  //not supported for symlinks
    }
    func readSymbolicLink() throws -> FSFileName {
        return FSFileName(string: data)
    }
}

class HardDependencyFSNode: FSItem, FSItemProtocol {
    let fileId: FSItem.Identifier
    let itemType: FSItem.ItemType = .directory
    internal let children: [PathSegment: FSItemProtocol]
    internal let parentId: FSItem.Identifier

    init(
        fileId: FSItem.Identifier, parentId: FSItem.Identifier,
        children: [PathSegment: FSItemProtocol]
    ) {
        self.fileId = fileId
        self.parentId = parentId
        self.children = children
    }
    func getChildren() throws -> [(FSFileName, FSItemProtocol)] {
        return children.map {
            (FSFileName(string: $0.key), $0.value)
        }
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
        attr.type = itemType
        attr.mode = UInt32(S_IFDIR | 0o755)  //by default node_modules created with 755
        return attr
    }

    func readSymbolicLink() throws -> FSFileName {
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)  //not supported for dirs
    }
}

final class ZipHardDependencyFSNode: HardDependencyFSNode {
    private let zipInfo: ZipInfo
    private var cachedRootId: ZipID? = nil

    init(
        fileId: FSItem.Identifier, parentId: FSItem.Identifier,
        children: [PathSegment: FSItemProtocol], zipInfo: ZipInfo
    ) {
        self.zipInfo = zipInfo
        super.init(fileId: fileId, parentId: parentId, children: children)
    }

    private var cachedZip: CachedZip {
        return zipInfo.cachedZip
    }

    private func getRootId(listableZip: ListableZip) throws -> ZipID {
        let rootId =
            try cachedRootId
            ?? {
                let rootId = try listableZip.getIdForPath(path: zipInfo.subpath)
                cachedRootId = rootId  // todo mutex?
                return rootId
            }()
        return rootId
    }

    private func getZipChildren() throws -> [PathSegment: ZipID] {
        let listableZip = try cachedZip.get()
        return listableZip.getChildren(forId: try getRootId(listableZip: listableZip))
    }

    override func getChildren() throws -> [(FSFileName, FSItemProtocol)] {
        var children = try super.getChildren()
        let zipChildren = try getZipChildren()
        children += zipChildren.map {
            (
                FSFileName(string: $0.key),
                ZipFSNode(cachedZip: cachedZip, zipId: $0.value, parentId: fileId)
            )
        }

        return children
    }
    override func getChild(name: FSFileName) throws -> FSItemProtocol? {
        if let child = try super.getChild(name: name) {
            return child
        }
        guard let name = name.string else {  //todo move to higher level? replace with bytes?
            return nil
        }
        let zipChildren = try getZipChildren()
        if let zipEntry = zipChildren[name] {
            return ZipFSNode(cachedZip: cachedZip, zipId: zipEntry, parentId: fileId)
        }
        return nil
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
