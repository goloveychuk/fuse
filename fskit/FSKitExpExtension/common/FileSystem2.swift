import FSKit
import Foundation

private struct NodeData {
    let rootNode: RootNode
    let zipId: ZipID?
}

private let uid = getuid()
private let gid = getgid()

private struct RootNode {
    // let fileId: FSItem.Identifier
    let rootNodeInd: UInt
    let parentInd: UInt
    let node: DependencyNode
    let zipInfo: ZipInfo?
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

class FileSystem2 {

    private var rootNodes = [RootNode]()
    private var zipCache = [PathSegment: CachedZip]()
    private let fileIdEncoder = FileIdEncoder()

    init(depNode: DependencyNode) {
        visit(dependencyNode: depNode, parentInd: 0)
    }

    private func visitChildren(children: Children, parentInd: UInt) {
        for child in children {
            visit(dependencyNode: child.value, parentInd: parentInd)
        }
    }

    private func visit(
        dependencyNode: DependencyNode, parentInd: UInt
    ) {
        let rootNodeInd = UInt(rootNodes.count)

        var zipInfo: ZipInfo?

        switch dependencyNode {
        case .softLink(_):
            break
        case .zip(let info, let children):

            if let cachedZip = zipCache[info.zipPath] {
                zipInfo = (cachedZip, subpath: info.subpath)
                cachedZip.refCount += 1
            } else {
                let cachedZip: CachedZip = CachedZip(zipPath: info.zipPath)
                zipCache[info.zipPath] = cachedZip
                zipInfo = (cachedZip, subpath: info.subpath)
            }
            visitChildren(children: children, parentInd: rootNodeInd)
        case .dirPortal(_, let children), .nestedDir(let children): 
            visitChildren(children: children, parentInd: rootNodeInd)
        }

        rootNodes.append(
            RootNode(rootNodeInd: rootNodeInd, parentInd: parentInd, node: dependencyNode, zipInfo: zipInfo))
    }

    private func getNodeByFileId(_ fileid: FSItem.Identifier) -> NodeData {
        let (rootNodeInd, type, zipInd) = fileIdEncoder.decodeTuple(encoded: fileid.rawValue)
        let rootNode = rootNodes[Int(rootNodeInd)]
        switch type {
        case 1:
            return NodeData(rootNode: rootNode, zipId: .file(entryId: zipInd))
        case 2:
            return NodeData(rootNode: rootNode, zipId: .symlink(entryId: zipInd))
        case 3:
            return NodeData(rootNode: rootNode, zipId: .dir(listingId: zipInd))
        case 0:
            return NodeData(rootNode: rootNode, zipId: nil)
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
        if (FSItem.Identifier.rootDirectory.rawValue != 0) {
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

    private func getAttributesForNodeData(nodeData: NodeData) throws -> FSItem.Attributes {
        var attributes: FSItem.Attributes
        if let zipId = nodeData.zipId {
            attributes = try getAttributesForZipID(
                zipId: zipId, rootNode: nodeData.rootNode)
        } else {
            attributes = getAttributesForRootNode(node: nodeData.rootNode)
        }
        return attributes
    }

    private func getAttributesForZipID(zipId: ZipID, rootNode: RootNode) throws -> FSItem.Attributes {
        let attr = FSItem.Attributes()

        let cachedZip = rootNode.zipInfo!.cachedZip
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
            attr.mode = UInt32(S_IFDIR | 0o755)  //by default node_modules created with 755
        case .symlink(_):
            attr.size = 1
            attr.allocSize = 1
            attr.type = .symlink
            attr.mode = UInt32(S_IFLNK | 0o644)  //todo get original, because there are executable
        case .file(let entryInd):
            let zipEntry = listableZip.getEntry(index: Int(entryInd))
            attr.linkCount = cachedZip.refCount
            attr.type = .file
            attr.size = UInt64(zipEntry.size)
            attr.allocSize = UInt64(zipEntry.compressedSize)  //todo not sure
            attr.mode = UInt32(S_IFREG | zipEntry.permissions)  // todo get original, because there are executable
        }
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

        switch nodeData.rootNode.node {
        case .softLink(let data):
            return verifier
        case .zip(_, let children), .dirPortal(_, let children), .nestedDir(let children):

            if cookie.rawValue < 1 {
                let attributes = try getAttributesForNodeData(nodeData: nodeData)
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
                        itemID: parentId, nextCookie: FSDirectoryCookie(2),
                        attributes: try directory.getAttributes()  //todo
                    )
                else {
                    return FSDirectoryVerifier(version)
                }
            }
            var currentOffset = 2
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
            if let zipId = nodeData.zipId {
                if case .zip(let zipInfo, _) = nodeData.rootNode.node {
                    let cachedZip = zipCache[zipInfo.zipPath]!
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
        }
        return FSDirectoryVerifier(version)

    }

}
