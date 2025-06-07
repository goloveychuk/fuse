import FSKit
import Foundation

private struct Inode {
    let rootNode: RootNode
    let zipId: ZipID?
}

private let uid = getuid()
private let gid = getgid()

private enum RootNodeData {
    case softLink(data: String)
    case zip(zipInfo: ZipInfo, children: [PathSegment: RootNode])
    case dirPortal(target: String, children: [PathSegment: RootNode])
    case nestedDir(children: [PathSegment: RootNode])
}

private struct RootNode {
    // let fileId: FSItem.Identifier
    let rootNodeInd: UInt
    let parentInd: UInt
    let node: RootNodeData

}

class FileIdEncoder {
    // Static bit allocation for the tuple encoding
    private let bitAllocation = (
        value1Bits: 31,
        value2Bits: 2,
        value3Bits: 31
    )
    private let value1Shift: Int
    private let value2Shift: Int
    private let value3Shift: Int
    private let value1Mask: UInt64
    private let value2Mask: UInt64
    private let value3Mask: UInt64

    init() {
        // Verify total bits don't exceed 64
        assert(
            bitAllocation.value1Bits + bitAllocation.value2Bits + bitAllocation.value3Bits == 64,
            "Total bits don't equal to UInt64 capacity")
        value1Shift = bitAllocation.value3Bits + bitAllocation.value2Bits
        value2Shift = bitAllocation.value3Bits
        value3Shift = 0
        value1Mask = UInt64((1 << bitAllocation.value1Bits) - 1) << value1Shift
        value2Mask = UInt64((1 << bitAllocation.value2Bits) - 1) << value2Shift
        value3Mask = UInt64((1 << bitAllocation.value3Bits) - 1) << value3Shift
    }
    func encodeTuple(value1: UInt, value2: UInt, value3: UInt) -> UInt64 {
        // Check for potential overflow based on bit allocation
        guard value1 < (1 << bitAllocation.value1Bits) else {
            fatalError(
                "value1 overflow: \(value1) is too large to fit in \(bitAllocation.value1Bits) bits"
            )
        }
        guard value2 < (1 << bitAllocation.value2Bits) else {
            fatalError(
                "value2 overflow: \(value2) is too large to fit in \(bitAllocation.value2Bits) bits"
            )
        }
        guard value3 < (1 << bitAllocation.value3Bits) else {
            fatalError(
                "value3 overflow: \(value3) is too large to fit in \(bitAllocation.value3Bits) bits"
            )
        }

        return (UInt64(value1) << value1Shift) | (UInt64(value2) << value2Shift)
            | (UInt64(value3) << value3Shift)
    }

    func decodeTuple(encoded: UInt64) -> (value1: UInt, value2: UInt, value3: UInt) {

        // Extract each value using the masks and shifts
        let value1 = UInt((encoded & value1Mask) >> value1Shift)
        let value2 = UInt((encoded & value2Mask) >> value2Shift)
        let value3 = UInt((encoded & value3Mask) >> value3Shift)

        return (value1, value2, value3)
    }

}

public class FileSystem {

    private var rootNodes = [RootNode]()
    private var zipCache = [PathSegment: CachedZip]()
    private let fileIdEncoder = FileIdEncoder()

    init(manifestPath: String) throws {
        let data = try Data(contentsOf: URL(filePath: manifestPath))
        let depTree = try DependencyNode.fromJSONData(data)

        _ = visit(dependencyNode: depTree, parentInd: 0)
    }

    private func visitChildren(children: Children, parentInd: UInt) -> [PathSegment: RootNode] {
        return children.mapValues { child in
            visit(dependencyNode: child, parentInd: parentInd)
        }
    }

    private func visit(
        dependencyNode: DependencyNode, parentInd: UInt
    ) -> RootNode {
        let rootNodeInd = UInt(rootNodes.count)

        let nodeData: RootNodeData

        switch dependencyNode {
        case .softLink(let data):
            nodeData = .softLink(data: data)
            break
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
            nodeData = .zip(
                zipInfo: zipInfo,
                children: visitChildren(children: children, parentInd: rootNodeInd))
        case .dirPortal(let target, let children):
            nodeData = .dirPortal(
                target: target, children: visitChildren(children: children, parentInd: rootNodeInd))
        case .nestedDir(let children):
            nodeData = .nestedDir(
                children: visitChildren(children: children, parentInd: rootNodeInd))
        }

        let rootNode = RootNode(
            rootNodeInd: rootNodeInd, parentInd: parentInd, node: nodeData)
        rootNodes.append(rootNode)
        return rootNode
    }

    private func getNodeByFileId(_ fileid: FSItem.Identifier) -> Inode {
        let (rootNodeInd, type, zipInd) = fileIdEncoder.decodeTuple(encoded: fileid.rawValue)
        let rootNode = rootNodes[Int(rootNodeInd)]
        switch type {
        case 1:
            return Inode(rootNode: rootNode, zipId: .file(entryId: zipInd))
        case 2:
            return Inode(rootNode: rootNode, zipId: .symlink(entryId: zipInd))
        case 3:
            return Inode(rootNode: rootNode, zipId: .dir(listingId: zipInd))
        case 0:
            return Inode(rootNode: rootNode, zipId: nil)
        default:
            fatalError("Invalid type: \(type)")
        }
    }

    private func getNodeId(rootNodeInd: UInt, zipId: ZipID?) -> FSItem.Identifier {
        var type: UInt
        var zipInd: UInt
        switch zipId {
        case .file(let entryId):
            zipInd = entryId
            type = 1
        case .symlink(let entryId):
            zipInd = entryId
            type = 2
        case .dir(let listingId):
            zipInd = listingId
            type = 3
        case .none:
            zipInd = 0
            type = 0
        }
        let fileId = fileIdEncoder.encodeTuple(value1: rootNodeInd, value2: type, value3: zipInd)
        // todo check
        if FSItem.Identifier.rootDirectory.rawValue != 0 {
            fatalError("FSItem.Identifier.rootDirectory is not 0")
        }
        // fileId = fileId + FSItem.Identifier.rootDirectory.rawValue
        return FSItem.Identifier(rawValue: fileId)!
    }

    private func getAttributesForRootNode(node: RootNode) -> FSItem.Attributes {
        let attr = FSItem.Attributes()
        attr.fileID = getNodeId(rootNodeInd: node.rootNodeInd, zipId: nil)
        attr.parentID = getNodeId(rootNodeInd: node.parentInd, zipId: nil)
        attr.uid = uid
        attr.gid = gid
        switch node.node {
        case .softLink(_):
            attr.size = 1
            attr.allocSize = 1
            attr.linkCount = 1
            attr.type = .symlink
            attr.mode = UInt32(S_IFLNK | 0o644)  //todo get original, because there are executable
            return attr
        case .zip(_, _), .dirPortal(_, _), .nestedDir(_):
            attr.size = 0
            attr.allocSize = 0
            attr.type = .directory
            attr.mode = UInt32(S_IFDIR | 0o755)  //by default node_modules created with 755
            return attr
        }
    }

    private func getAttributesForNodeData(nodeData: Inode) throws -> FSItem.Attributes {
        var attributes: FSItem.Attributes
        if let zipId = nodeData.zipId {
            attributes = try getAttributesForZipID(
                zipId: zipId, rootNode: nodeData.rootNode)
        } else {
            attributes = getAttributesForRootNode(node: nodeData.rootNode)
        }
        return attributes
    }

    private func getAttributesForZipID(zipId: ZipID, rootNode: RootNode) throws -> FSItem.Attributes
    {
        let attr = FSItem.Attributes()
        guard case .zip(let zipInfo, _) = rootNode.node else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        let cachedZip = zipInfo.cachedZip
        let listableZip = try cachedZip.get()
        let zipParent = listableZip.getParentForZipID(zipID: zipId)

        attr.fileID = getNodeId(rootNodeInd: rootNode.rootNodeInd, zipId: zipId)
        attr.parentID = getNodeId(rootNodeInd: rootNode.rootNodeInd, zipId: zipParent)
        attr.uid = uid
        attr.gid = gid
        switch zipId {
        case .dir(_):
            attr.size = 0
            attr.allocSize = 0
            attr.linkCount = 1
            attr.type = .directory
            attr.mode = UInt32(S_IFDIR | 0o755)  //todo get original
        case .symlink(let entryInd):
            let zipEntry = listableZip.getEntry(index: entryInd)
            attr.size = 1
            attr.allocSize = 1
            attr.type = .symlink
            attr.mode = UInt32(S_IFLNK | zipEntry.permissions)
        case .file(let entryInd):
            let zipEntry = listableZip.getEntry(index: entryInd)
            attr.linkCount = cachedZip.refCount
            attr.type = .file
            attr.size = UInt64(zipEntry.size)
            attr.allocSize = UInt64(zipEntry.compressedSize)  //todo not sure
            attr.mode = UInt32(S_IFREG | zipEntry.permissions)
        }
        return attr
    }

    public func getAttributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of fileId: FSItem.Identifier
    ) async throws -> FSItem.Attributes {
        let nodeData = getNodeByFileId(fileId)
        return try getAttributesForNodeData(nodeData: nodeData)
    }

    public func lookupItem(
        _ name: FSFileName,
        inDirectory directory: FSItem.Identifier
    ) async throws -> (FSItem.Identifier, FSFileName) {
        let nodeData = getNodeByFileId(directory)

        // let identifier = FSItem.Identifier(rawValue: 0)!  //todo
        return (identifier, name)
    }

    private func getChildrenData(nodeData: Inode) throws -> (
        children: [PathSegment: RootNode]?, childrenForZipId: (ZipInfo, ZipID)?
    ) {
        switch nodeData.rootNode.node {
        case .softLink(_):
            return (nil, nil)
        case .zip(let zipInfo, let children):
            if let zipId = nodeData.zipId {
                return (nil, (zipInfo, zipId))
            } else {
                let zipId = try zipInfo.cachedZip.get().getIdForPath(
                    path: ZipPath(path: zipInfo.subpath))
                return (children, (zipInfo, zipId))
            }
        case .dirPortal(_, let children):
            return (children, nil)
        case .nestedDir(let children):
            return (children, nil)
        }
    }
    public func enumerateDirectory(
        directory: FSItem.Identifier,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes req: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,

    ) async throws -> FSDirectoryVerifier {
        let nodeData = getNodeByFileId(directory)
        let version = UInt64(0)  //todo

        switch nodeData.rootNode.node {
        case .softLink(_):
            return verifier
        case .zip(_, let children), .dirPortal(_, let children), .nestedDir(let children):
            let attributes = try getAttributesForNodeData(nodeData: nodeData)
            if cookie.rawValue < 1 {
                guard
                    packer.packEntry(
                        name: FSFileName(string: "."), itemType: .directory, itemID: directory,
                        nextCookie: FSDirectoryCookie(1), attributes: attributes)
                else {
                    return FSDirectoryVerifier(version)
                }
            }

            if cookie.rawValue < 2 {
                guard
                    packer.packEntry(
                        name: FSFileName(string: ".."), itemType: .directory,
                        itemID: attributes.parentID, nextCookie: FSDirectoryCookie(2),
                        attributes: nil  // I don't think it's needed, check
                    )
                else {
                    return FSDirectoryVerifier(version)
                }
            }
            var currentOffset = 2

            let childrenData = try getChildrenData(nodeData: nodeData)

            if let children = childrenData.children {
                for (name, child) in children {
                    defer {
                        currentOffset += 1
                    }
                    if currentOffset < cookie.rawValue {
                        continue
                    }

                    let attributes = getAttributesForRootNode(node: child)
                    let ok = packer.packEntry(
                        name: FSFileName(string: name),
                        itemType: attributes.type,
                        itemID: attributes.fileID,
                        nextCookie: FSDirectoryCookie(UInt64(currentOffset + 1)),
                        attributes: attributes,
                    )

                    if !ok {
                        // fskit dont't want to continue
                        return FSDirectoryVerifier(version)
                    }
                }
            }

            if let (zipInfo, zipId) = childrenData.childrenForZipId {
                let cachedZip = zipInfo.cachedZip
                let zip = try cachedZip.get()
                let zipEntries = zip.getChildren(forId: zipId)
                for (name, zipId) in zipEntries.entries() {
                    defer {
                        currentOffset += 1
                    }
                    if currentOffset < cookie.rawValue {
                        continue
                    }
                    let attributes = try getAttributesForZipID(
                        zipId: zipId, rootNode: nodeData.rootNode)
                    let ok = packer.packEntry(
                        name: name,
                        itemType: attributes.type,
                        itemID: attributes.fileID,
                        nextCookie: FSDirectoryCookie(UInt64(currentOffset + 1)),
                        attributes: attributes,
                    )

                    if !ok {
                        // fskit dont't want to continue
                        return FSDirectoryVerifier(version)

                    }
                }
            }
        }
        return FSDirectoryVerifier(version)

    }

    public func readSymbolicLink(_ fileID: FSItem.Identifier) async throws -> FSFileName {

        let nodeData = getNodeByFileId(fileID)
        if let zipId = nodeData.zipId {
            guard case .zip(let zipInfo, _) = nodeData.rootNode.node else {
                throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
            }
            if case .symlink(let entryInd) = zipId {
                let data = try readFileToBuffer(
                    entryInd: entryInd, cachedZip: zipInfo.cachedZip)
                return FSFileName(data: data)
            }
        } else {
            if case .softLink(let data) = nodeData.rootNode.node {
                return FSFileName(string: data)
            }
        }
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
    }

    private func readFileToBuffer(entryInd: UInt, cachedZip: CachedZip) throws -> Data {

        let listableZip = try cachedZip.get()
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

    func readData(
        _ fileID: FSItem.Identifier, offset: off_t, length: Int,
        into buffer: FSMutableFileDataBuffer
    ) async throws -> Int {
        let nodeData = getNodeByFileId(fileID)

        guard let zipId = nodeData.zipId else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        guard case .zip(let zipInfo, _) = nodeData.rootNode.node else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        switch zipId {
        case .symlink(_):
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)

        case .file(let entryInd):
            let listableZip = try zipInfo.cachedZip.get()
            let zipEntry = listableZip.getEntry(index: entryInd)
            switch zipEntry.compressionMethod {
            case .deflate:
                let compressedData = try readFileToBuffer(
                    entryInd: entryInd, cachedZip: zipInfo.cachedZip)

                // Create a temporary buffer for decompressed data
                let destinationSize = Int(zipEntry.size)

                // If offset is beyond the file size, return 0 bytes read
                if offset >= destinationSize {
                    return 0
                }

                let decompressedData = try decompressDeflate(
                    compressedData: compressedData, destinationSize: destinationSize)
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

}
