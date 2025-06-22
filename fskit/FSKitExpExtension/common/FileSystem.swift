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
    case zip(zipInfo: ZipInfo, children: OrderedDictionary<PathSegment, RootNode>)
    case dirPortal(target: String, children: OrderedDictionary<PathSegment, RootNode>)
    case nestedDir(children: OrderedDictionary<PathSegment, RootNode>)
}


private struct RootNode: Sendable {
    // let fileId: FSItem.Identifier
    let rootNodeInd: UInt
    let parentInd: UInt
    let node: RootNodeData
}

final class FileIdEncoder: Sendable {
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


class Visitor {
    fileprivate var rootNodes = [RootNode]()
    fileprivate var zipCache = [PathSegment: CachedZip]()    
    private let writableConfig: WritableConfig?
    init(depTree: DependencyNode, writableConfig: WritableConfig?) {
        self.writableConfig = writableConfig
        _ = visit(dependencyNode: depTree, parentInd: 0)

    }
    private func visitChildren(children: Children, parentInd: UInt) -> OrderedDictionary<PathSegment, RootNode> {
        return OrderedDictionary(children.mapValues { child in
            visit(dependencyNode: child, parentInd: parentInd)
        })
    }
    private func visit(
        dependencyNode: DependencyNode, parentInd: UInt
    ) -> RootNode {
        let rootNodeInd = UInt(rootNodes.count)
        //this is a hack, because idk how to make holes in array, will be replaced later.
        rootNodes.append(
            RootNode(rootNodeInd: UInt.max, parentInd: UInt.max, node: .nestedDir(children: OrderedDictionary([:]))))
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
                let cachedZip = CachedZip { [writableConfig] in
                    if let writableConfig = writableConfig {
                        try await WritableZip(config: writableConfig, fileURL: URL(fileURLWithPath: info.zipPath))
                    } else {
                        try await ListableZip(fileURL: URL(fileURLWithPath: info.zipPath))
                    }
                }
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
        rootNodes[Int(rootNodeInd)] = rootNode
        return rootNode
    }
}

public final class FileSystem: Sendable {

    private let rootNodes: [RootNode]
    private let zipCache: [PathSegment: CachedZip]
    private let fileIdEncoder = FileIdEncoder()

    public init(manifestPath: String, mutationsPath: String?) throws {
        let data = try Data(contentsOf: URL(filePath: manifestPath))
        let depTree = try DependencyNode.fromJSONData(data)
        let writableConfig: WritableConfig? = if let mutationsPath = mutationsPath {
            WritableConfig(mutationsPath: mutationsPath)
        } else {
            nil
        }
        let visitor = Visitor(depTree: depTree, writableConfig: writableConfig)
        self.rootNodes = visitor.rootNodes
        self.zipCache = visitor.zipCache
        startCleaningWorker()
    }


    private func startCleaningWorker() {
        Task { [zipCache] in
            while true {
                try await Task.sleep(for: .seconds(20))
                for (_, cachedZip) in zipCache {
                    await cachedZip.cleanIfNeeded()
                }
            }
        }
    }

    
    private func getNodeByFileId(_ fileid: FSItem.Identifier) -> Inode {
        let (rootNodeInd, type, zipInd) = fileIdEncoder.decodeTuple(
            encoded: fileid.rawValue - FSItem.Identifier.rootDirectory.rawValue)
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

    public func getRootIdentifier() -> FSItem.Identifier {
        return getNodeId(rootNodeInd: 0, zipId: nil)
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
        // if FSItem.Identifier.rootDirectory.rawValue != 0 {
        //     fatalError("FSItem.Identifier.rootDirectory is not 0")
        // }
        // root node should be 0
        return FSItem.Identifier(rawValue: fileId + FSItem.Identifier.rootDirectory.rawValue)!  //check overflow
    }

    private func getAttributesForNodeData(nodeData: Inode, req: FSItem.GetAttributesRequest) async throws
        -> FSItem.Attributes
    {
        var attributes: FSItem.Attributes
        if let zipId = nodeData.zipId {
            attributes = try await getAttributesForZipID(
                zipId: zipId, rootNode: nodeData.rootNode, req: req)
        } else {
            attributes = getAttributesForRootNode(node: nodeData.rootNode, req: req)
        }
        return attributes
    }

    private func getItemType(rootNode: RootNode, zipID: ZipID?) -> FSItem.ItemType {
        if let zipID = zipID {
            switch zipID {
            case .dir(_):
                return .directory
            case .file(_):
                return .file
            case .symlink(_):
                return .symlink
            }
        } else {
            switch rootNode.node {
            case .softLink(_):
                return .symlink
            case .zip(_, _), .dirPortal(_, _), .nestedDir(_):
                return .directory
            }
        }
    }

    private func getAttributesForRootNode(node: RootNode, req: FSItem.GetAttributesRequest)
        -> FSItem.Attributes
    {
        let attr = FSItem.Attributes()
        attr.fileID = getNodeId(rootNodeInd: node.rootNodeInd, zipId: nil)
        if req.isAttributeWanted(.parentID) {
            if attr.fileID == .rootDirectory {
                attr.parentID = .parentOfRoot
            } else {
                attr.parentID = getNodeId(rootNodeInd: node.parentInd, zipId: nil)
            }
        }
        // "uid, modifyTime, fileID, type, mode, flags, accessTime, gid, size, birthTime, "
        attr.uid = uid
        attr.gid = gid
        attr.type = getItemType(rootNode: node, zipID: nil)
        switch node.node {
        case .softLink(_):
            attr.size = 1
            attr.allocSize = 1
            attr.linkCount = 1
            attr.mode = UInt32(S_IFLNK | 0o644)  //todo get original, because there are executable
            return attr
        case .zip(_, _), .dirPortal(_, _), .nestedDir(_):
            attr.size = 0
            attr.allocSize = 0
            attr.linkCount = 1
            attr.mode = UInt32(S_IFDIR | 0o755)  //by default node_modules created with 755
            return attr
        }
    }
    

    private func getAttributesForZipID(
        zipId: ZipID, rootNode: RootNode, req: FSItem.GetAttributesRequest
    ) async throws -> FSItem.Attributes {
        let attr = FSItem.Attributes()
        guard case .zip(let zipInfo, _) = rootNode.node else {
            throw fs_errorForPOSIXError(POSIXError.EIO)
        }
        let cachedZip = zipInfo.cachedZip
        let listableZip = try await cachedZip.get()

        attr.fileID = getNodeId(rootNodeInd: rootNode.rootNodeInd, zipId: zipId)
        if req.isAttributeWanted(.parentID) {
            let zipParent = listableZip.listable.getParentForZipID(zipID: zipId)
            attr.parentID = getNodeId(rootNodeInd: rootNode.rootNodeInd, zipId: zipParent)
        }
        attr.uid = uid
        attr.gid = gid
        attr.type = getItemType(rootNode: rootNode, zipID: zipId)
        switch zipId {
        case .dir(_):
            attr.size = 0
            attr.allocSize = 0
            attr.linkCount = 1
            attr.mode = UInt32(S_IFDIR | 0o755)  //todo get original
        case .symlink(let entryInd):
            let zipEntry = try listableZip.statEntry(index: entryInd)
            attr.size = 1
            attr.allocSize = 1
            attr.linkCount = 1
            attr.mode = UInt32(S_IFLNK | zipEntry.permissions)
        case .file(let entryInd):
            let zipEntry = try listableZip.statEntry(index: entryInd)
            attr.linkCount = cachedZip.refCount
            attr.size = UInt64(zipEntry.size)
            attr.allocSize = UInt64(zipEntry.allocSize)  //todo not sure
            attr.mode = UInt32(S_IFREG | zipEntry.permissions)
        }
        return attr
    }

    public func getAttributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of fileId: FSItem.Identifier,
    ) async throws -> FSItem.Attributes {
        // let wanted = desiredAttributes.printRequestedAttributes
        // "modifyTime, size, birthTime, parentID, type, flags, allocSize, mode, linkCount, changeTime, accessTime, fileID, "
        let nodeData = getNodeByFileId(fileId)
        return try await getAttributesForNodeData(nodeData: nodeData, req: desiredAttributes)
    }

    public func lookupItem(
        _ name: FSFileName,
        inDirectory directory: FSItem.Identifier
    ) async throws -> (FSItem.Identifier, FSFileName) {
        // todo . and ..?
        let strName = name.string!
        if strName == "." || strName == ".." {
            throw fs_errorForPOSIXError(POSIXError.EIO)
        }
        let nodeData = getNodeByFileId(directory)
        let childrenData = try await getChildrenData(nodeData: nodeData)

        if let children = childrenData.children {
            guard let strName = name.string else {
                throw fs_errorForPOSIXError(POSIXError.ENOENT)
            }
            if let child = children[strName] {
                let identifier = getNodeId(rootNodeInd: child.rootNodeInd, zipId: nil)
                return (identifier, name)
            }
        }
        if let (zipInfo, zipId) = childrenData.childrenForZipId {
            let zipEntries = try await getZipChildren(zipInfo: zipInfo, zipId: zipId)
            if let child = zipEntries[name.data] {
                let identifier = getNodeId(rootNodeInd: nodeData.rootNode.rootNodeInd, zipId: child)
                return (identifier, name)
            }
        }
        throw fs_errorForPOSIXError(POSIXError.ENOENT)
    }

    private func getChildrenData(nodeData: Inode) async throws -> (
        children: OrderedDictionary<PathSegment, RootNode>?, childrenForZipId: (ZipInfo, ZipID)?
    ) {
        switch nodeData.rootNode.node {
        case .softLink(_):
            throw fs_errorForPOSIXError(POSIXError.ENOTDIR)
            // return (nil, nil)
        case .zip(let zipInfo, let children):
            if let zipId = nodeData.zipId {
                guard case .dir(_) = zipId else {
                    throw fs_errorForPOSIXError(POSIXError.ENOTDIR)
                }
                return (nil, (zipInfo, zipId))
            } else {
                let zipId = try await zipInfo.cachedZip.get().listable.getIdForPath(
                    path: ZipPath(path: zipInfo.subpath))
                guard case .dir(_) = zipId else {
                    throw fs_errorForPOSIXError(POSIXError.ENOTDIR)
                }
                return (children, (zipInfo, zipId))
            }
        case .dirPortal(_, let children):
            return (children, nil)
        case .nestedDir(let children):
            return (children, nil)
        }
    }

    private func getZipChildren(zipInfo: ZipInfo, zipId: ZipID) async throws -> Indexed<ZipID> {
        let cachedZip = zipInfo.cachedZip
        let zip = try await cachedZip.get()
        let zipEntries = zip.listable.getChildren(forId: zipId)
        return zipEntries
    }

    private func createDotDotAttributes(itemID: FSItem.Identifier) -> FSItem.Attributes {
        //todo impl correctly
        let attr = FSItem.Attributes()
        attr.fileID = itemID
        attr.uid = uid
        attr.gid = gid
        attr.linkCount = 2
        attr.type = .directory
        attr.mode = UInt32(S_IFDIR | 0o755)
        attr.size = 0
        return attr
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
        var currentOffset = UInt64(0)

        // let wanted = req?.printRequestedAttributes
        if cookie.rawValue <= currentOffset {
            guard
                packer.packEntry(
                    name: FSFileName(string: "."), itemType: .directory, itemID: directory,
                    nextCookie: FSDirectoryCookie(currentOffset + 1), 
                    attributes: req != nil ? createDotDotAttributes(itemID: directory) : nil  // I don't think it's needed, check
                    )
            else {
                return FSDirectoryVerifier(version)
            }
        }
        currentOffset += 1

        if cookie.rawValue <= currentOffset {
            let attributes = try await getAttributesForNodeData(
                nodeData: nodeData, req: FSItem.GetAttributesRequest([.parentID]))
            guard
                packer.packEntry(
                    name: FSFileName(string: ".."), itemType: .directory,
                    itemID: attributes.parentID, nextCookie: FSDirectoryCookie(currentOffset + 1),
                    attributes: req != nil ? createDotDotAttributes(itemID: attributes.parentID) : nil  // I don't think it's needed, check
                )
            else {
                return FSDirectoryVerifier(version)
            }
        }
        currentOffset += 1

        let childrenData = try await getChildrenData(nodeData: nodeData)

        if let children = childrenData.children {
            let listing = children.getListing()
            let skip = cookie.rawValue > currentOffset ? min(cookie.rawValue - currentOffset, UInt64(listing.count)) : 0
            currentOffset += skip
            for (name, child) in listing.dropFirst(Int(skip)) {
                defer {
                    currentOffset += 1
                }
                let ok = packer.packEntry(
                    name: FSFileName(string: name),
                    itemType: getItemType(rootNode: child, zipID: nil),
                    itemID: getNodeId(rootNodeInd: child.rootNodeInd, zipId: nil),
                    nextCookie: FSDirectoryCookie(UInt64(currentOffset + 1)),
                    attributes: req != nil ? getAttributesForRootNode(node: child, req: req!) : nil,
                )

                if !ok {
                    // fskit dont't want to continue
                    return FSDirectoryVerifier(version)
                }
            }
        }

        if let (zipInfo, zipId) = childrenData.childrenForZipId {
            let zipEntries = try await getZipChildren(zipInfo: zipInfo, zipId: zipId)
            let listing = zipEntries.getListing()
            let skip = cookie.rawValue > currentOffset ? min(cookie.rawValue - currentOffset, UInt64(listing.count)) : 0
            currentOffset += skip

            for (name, zipId) in listing.dropFirst(Int(skip)) {
                defer {
                    currentOffset += 1
                }
                // todo  do it in insert level
                // if let children = childrenData.children {
                //     if children[name.string!] != nil {
                //         continue
                //     }
                // }

                let ok = packer.packEntry(
                    name: FSFileName(data: name),
                    itemType: getItemType(rootNode: nodeData.rootNode, zipID: zipId),
                    itemID: getNodeId(rootNodeInd: nodeData.rootNode.rootNodeInd, zipId: zipId),
                    nextCookie: FSDirectoryCookie(UInt64(currentOffset + 1)),
                    attributes: req != nil
                        ? try await getAttributesForZipID(
                            zipId: zipId, rootNode: nodeData.rootNode, req: req!) : nil,
                )

                if !ok {
                    // fskit dont't want to continue
                    return FSDirectoryVerifier(version)

                }
            }
        }

        return FSDirectoryVerifier(version)

    }

    public func readSymbolicLink(_ fileID: FSItem.Identifier) async throws -> FSFileName {
        let nodeData = getNodeByFileId(fileID)
        if let zipId = nodeData.zipId {
            guard case .zip(let zipInfo, _) = nodeData.rootNode.node else {
                throw fs_errorForPOSIXError(POSIXError.EIO)
            }
            if case .symlink(let entryInd) = zipId {
                let listableZip = try await zipInfo.cachedZip.get()
                let data = try listableZip.readLink(index: entryInd)
                return FSFileName(data: data)
            }
        } else {
            if case .softLink(let data) = nodeData.rootNode.node {
                return FSFileName(string: data)
            }
        }
        throw fs_errorForPOSIXError(POSIXError.EIO)
    }

    public  func writeData(_ fileId: FSItem.Identifier, data: Data, offset: off_t) async throws -> Int {
        let nodeData = getNodeByFileId(fileId)
        guard let zipId = nodeData.zipId else {
            throw fs_errorForPOSIXError(POSIXError.EROFS)
        }
        guard case .zip(let zipInfo, _) = nodeData.rootNode.node else {
            throw fs_errorForPOSIXError(POSIXError.EROFS)
        }
        switch zipId {
        case .symlink(_):
            throw fs_errorForPOSIXError(POSIXError.EROFS)
        case .file(let entryInd):
            let listableZip = try await zipInfo.cachedZip.get()
            return try listableZip.writeData(index: entryInd, data: data, offset: offset)
        case .dir(_):
            throw fs_errorForPOSIXError(POSIXError.EROFS)
        }
    }

    public func readData(
        _ fileID: FSItem.Identifier, offset: off_t, length: Int,
        into buffer: MutableBufferLike
    ) async throws -> Int {
        let nodeData = getNodeByFileId(fileID)

        guard let zipId = nodeData.zipId else {
            throw fs_errorForPOSIXError(POSIXError.ENOENT)
        }
        guard case .zip(let zipInfo, _) = nodeData.rootNode.node else {
            throw fs_errorForPOSIXError(POSIXError.EIO)
        }
        switch zipId {
        case .symlink(_):
            throw fs_errorForPOSIXError(POSIXError.EIO)

        case .file(let entryInd):
            let listableZip = try await zipInfo.cachedZip.get()
            return try listableZip.readData(index: entryInd, offset: offset, length: length, buffer: buffer)
            
        case .dir(_):
            throw fs_errorForPOSIXError(POSIXError.EISDIR)
        }
    }

}
