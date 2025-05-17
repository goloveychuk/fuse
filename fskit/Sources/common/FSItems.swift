import FSKit
import Foundation

typealias PathSegment = String

// Define the LinkType enum
enum LinkType: String, Decodable {
    case HARD
    case SOFT
}

// Define custom errors for dependency operations

enum MyError: Error, LocalizedError, CustomNSError {
    case badManifest(String)
    case badMountParams
    
    var errorDescription: String? {
        switch self {
        case .badManifest(let err):
            return "Bad manifest: \(err)"
        case .badMountParams:
            return "Bad mount parameters"
        }
    }
    
    // var failureReason: String? {
    //     switch self {
    //     case .badManifest(let err):
    //         return "Bad manifest: \(err)"
    //     case .badMountParams:
    //         return "Bad mount parameters"   
    //     }
    // }
    
    // CustomNSError implementation
    // static var errorDomain: String { return "FSKitExpExtension.MyError" }
    
    var errorUserInfo: [String: Any] {
        return [
            NSLocalizedDescriptionKey: errorDescription ?? "",
            NSLocalizedFailureReasonErrorKey: failureReason ?? ""
        ]
    }
}

// extension FSFileName: Comparable {
//     public static func < (lhs: FSFileName, rhs: FSFileName) -> Bool {
//         for i in 0..<min(lhs.data.count, rhs.data.count) {
//             let delta = Int(lhs.data[i]) - Int(rhs.data[i])
//             if (delta == 0) {
//                 continue
//             }
//             return delta < 0
//         }
//         return lhs.data.count < rhs.data.count
//     }
//     public static func == (lhs: FSFileName, rhs: FSFileName) -> Bool {
//         return lhs.data == rhs.data
//     }
// }



// Typealias for zip information
typealias ZipPathInfo = (zipPath: String, subpath: String)

typealias Children = [PathSegment: DependencyNode]

typealias SoftLinkData = String
// Define the DependencyNode enum
enum DependencyNode: Decodable {
    case softLink(data: SoftLinkData)
    case zip(zipInfo: ZipPathInfo, children: Children)
    case dirPortal(target: String, children: Children)
    case nestedDir(children: Children)

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

            let children = try container.decode(
                Children.self, forKey: .children)

            // Validate children paths
            for (key, _) in children {
                // Check that the key (path segment) is a valid file or directory name
                // and doesn't contain nested path components
                if key.contains("/") {
                    throw MyError.badManifest("Invalid path segment: '\(key)'. Path segments should not contain nested paths.")
                }
            }

            if let targetPath = target {
                if let zipRange = targetPath.range(of: ".zip") {
                    let zipPath = String(targetPath[..<zipRange.upperBound])
                    var subpath = String(targetPath[zipRange.upperBound...])
                    if subpath.isEmpty {
                        subpath = "/"
                    }
                    self = .zip(zipInfo: (zipPath: zipPath, subpath: subpath), children: children)
                } else {
                    throw MyError.badManifest("Dir portal is not supported")
                    // self = .dirPortal(target: targetPath, children: children)
                }
            } else {
                self = .nestedDir(children: children)
            }

        // Check if the target has a .zip extension

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
        case .file(_, _):
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
        case .file(let entryInd, _), .symlink(let entryInd):
            self.fileId = parentId.advance(by: 10000 + entryInd)  //todo
        }
    }

    func getChildren() throws -> [(FSFileName, FSItemProtocol)] {
        let zip = try cachedZip.get()
        let zipEntries = zip.getChildren(forId: zipId)
        return zipEntries.entries().map {
            (
                $0.0,
                ZipFSNode(cachedZip: cachedZip, zipId: $0.1, parentId: fileId)
            )
        }
    }
    func getChild(name: FSFileName) throws -> FSItemProtocol? {
        let zip = try cachedZip.get()
        let zipEntries = zip.getChildren(forId: zipId)
        if let zipEntry = zipEntries[name] {
            return ZipFSNode(cachedZip: cachedZip, zipId: zipEntry, parentId: parentId)
        }
        return nil
    }

    func readSymbolicLink() throws -> FSFileName {
        guard case .symlink(let entryInd) = zipId else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        let data = try readFileToBuffer(entryInd: entryInd)
        return FSFileName(data: data)
    }

    private func readFileToBuffer(entryInd: Int) throws -> Data {
        let listableZip = try self.cachedZip.get()
        let zipEntry = listableZip.getEntry(index: entryInd)
        var data = Data(capacity: Int(zipEntry.compressedSize))
        let read = try data.withUnsafeMutableBytes { (body: UnsafeMutableRawBufferPointer) in
            return try listableZip.readData(
                index: entryInd, offset: 0, length: Int(zipEntry.compressedSize),
                bufferPointer: body)
        }
        if read != zipEntry.compressedSize {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        return data
    }

    func readData(offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) throws -> Int {
        switch zipId {
        case .symlink(_):
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)

        case .file(let entryInd, _):
            let listableZip = try self.cachedZip.get()
            let zipEntry = listableZip.getEntry(index: entryInd)
            switch zipEntry.compressionMethod {
            case .deflate:
                let compressedData = try readFileToBuffer(entryInd: entryInd)
                
                // Create a temporary buffer for decompressed data
                let destinationSize = Int(zipEntry.size)
                
                // If offset is beyond the file size, return 0 bytes read
                if offset >= destinationSize {
                    return 0
                }                
                
                let decompressedData = try decompressDeflate(compressedData: compressedData, destinationSize: destinationSize)
                // Calculate how many bytes to copy accounting for offset and available data
                let availableBytes = destinationSize - Int(offset)
                let bytesToCopy = min(availableBytes, length)
                
                // Copy the decompressed data to the output buffer, respecting offset
                return buffer.withUnsafeMutableBytes { outputBuffer in
                    decompressedData.withUnsafeBytes { sourceBuffer in
                        let source = sourceBuffer.baseAddress!.advanced(by: Int(offset))
                        memcpy(outputBuffer.baseAddress!, source, bytesToCopy)
                        return bytesToCopy
                    }
                }

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
        case .file(let entryInd, let permissions):
            let listableZip = try self.cachedZip.get()
            let zipEntry = listableZip.getEntry(index: entryInd)
            attr.linkCount = cachedZip.refCount
            attr.size = UInt64(zipEntry.size)
            attr.allocSize = UInt64(zipEntry.compressedSize)  //todo not sure
            attr.mode = UInt32(S_IFREG | permissions)  // todo get original, because there are executable
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

        case .dirPortal(_, let children), .nestedDir(let children):  //todo impl
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
                let rootId = try listableZip.getIdForPath(path: ZipPath(path: zipInfo.subpath))
                cachedRootId = rootId  // todo mutex?
                return rootId
            }()
        return rootId
    }

    private func getZipChildren() throws -> Indexed<ZipID> {
        let listableZip = try cachedZip.get()
        return listableZip.getChildren(forId: try getRootId(listableZip: listableZip))
    }

    override func getChildren() throws -> [(FSFileName, FSItemProtocol)] {
        var children = try super.getChildren()
        let zipChildren = try getZipChildren()
        children += zipChildren.entries().map {
            (
                $0.0,
                ZipFSNode(cachedZip: cachedZip, zipId: $0.1, parentId: fileId)
            )
        }

        return children
    }
    override func getChild(name: FSFileName) throws -> FSItemProtocol? {
        if let child = try super.getChild(name: name) {
            return child
        }
        let zipChildren = try getZipChildren()
        if let zipEntry = zipChildren[name] {
            return ZipFSNode(cachedZip: cachedZip, zipId: zipEntry, parentId: fileId)
        }
        return nil
    }

}
