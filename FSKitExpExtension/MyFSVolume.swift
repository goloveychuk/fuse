//
//  MyFSVolume.swift
//  FSKitExp
//
//  Created by Khaos Tian on 3/30/25.
//

import FSKit
import Foundation
import os

final class MyFSVolume: FSVolume {

    private let resource: FSResource

    private var depTree: DependencyNode?
    var mount3: FSTaskOptions? = nil

    private let logger = Logger(subsystem: "FSKitExp", category: "MyFSVolume")

    init(resource: FSResource) {
        self.resource = resource

        super.init(
            volumeID: FSVolume.Identifier(uuid: Constants.volumeIdentifier),
            volumeName: FSFileName(string: "Test1")
        )
    }
}

extension MyFSVolume: FSVolume.PathConfOperations {

    var maximumLinkCount: Int {
        return -1
    }

    var maximumNameLength: Int {
        return -1
    }

    var restrictsOwnershipChanges: Bool {
        return false
    }

    var truncatesLongNames: Bool {
        return false
    }

    var maximumXattrSize: Int {
        return Int.max
    }

    var maximumFileSize: UInt64 {
        return UInt64.max
    }
}

extension MyFSVolume: FSVolume.Operations {

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        logger.debug("supportedVolumeCapabilities")

        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsHardLinks = true
        capabilities.supportsSymbolicLinks = true
        capabilities.supportsPersistentObjectIDs = true
        capabilities.doesNotSupportVolumeSizes = true
        capabilities.supportsHiddenFiles = true
        capabilities.supports64BitObjectIDs = true
        capabilities.caseFormat = .insensitiveCasePreserving
        return capabilities
    }

    var volumeStatistics: FSStatFSResult {
        logger.debug("volumeStatistics")

        let result = FSStatFSResult(fileSystemTypeName: "MyFS")

        result.blockSize = 1_024_000
        result.ioSize = 1_024_000
        result.totalBlocks = 1_024_000
        result.availableBlocks = 1_024_000
        result.freeBlocks = 1_024_000
        result.totalFiles = 1_024_000
        result.freeFiles = 1_024_000

        return result
    }

    func activate(options: FSTaskOptions) async throws -> FSItem {
        self.mount3 = options
        logger.debug("activate")

        do {
            let root = try {
                let data = try Data(
                    contentsOf: URL(
                        filePath:
                            "/Users/vadymh/Library/Containers/app.badim.FSKitExpExtension/data/deptree.json"
                    ))
                let depTree = try DependencyNode.fromJSONData(data)
                let depFsNode = DependencyFSNode.buildTree(from: depTree)
                return depFsNode
            }()
            return root

        } catch {
            logger.error("Error mounting: \(error)")
            throw error
        }
        // let root: MyFSItem = {
        //     let item = MyFSItem(name: FSFileName(string: "/"))
        //     item.attributes.parentID = .parentOfRoot
        //     item.attributes.fileID = .rootDirectory
        //     item.attributes.uid = uid
        //     item.attributes.gid = gid
        //     item.attributes.linkCount = 1
        //     item.attributes.type = .directory
        //     item.attributes.mode = UInt32(S_IFDIR | 0b111_000_000)
        //     item.attributes.allocSize = 1
        //     item.attributes.size = 1
        //     return item
        // }()
    }

    func deactivate(options: FSDeactivateOptions = []) async throws {
        logger.debug("deactivate")
    }

    func mount(options: FSTaskOptions) async throws {
        logger.debug("mount")
    }

    func unmount() async {
        logger.debug("unmount")
    }

    func synchronize(flags: FSSyncFlags) async throws {
        logger.debug("synchronize")
    }

    func attributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem
    ) async throws -> FSItem.Attributes {
        if let item = item as? FSItemProtocol {
            // logger.debug("getItemAttributes1: \(item.name), \(desiredAttributes)")
            return try item.getAttributes()
        } else {
            logger.debug("getItemAttributes2: \(item), \(desiredAttributes)")
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem
    ) async throws -> FSItem.Attributes {
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)

        // logger.debug("setItemAttributes: \(item), \(newAttributes)")
        // if let item = item as? FSItemProtocol {
        //     mergeAttributes(item.attributes, request: newAttributes)
        //     return item.attributes
        // } else {
        //     throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        // }
    }

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> (FSItem, FSFileName) {
        logger.debug("lookupName: \(String(describing: name.string)), \(directory)")

        guard let directory = directory as? FSItemProtocol else {
            throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
        }

        if let item = try directory.getChild(name: name) {
            return (item, name)
        } else {
            throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
        }
    }

    func reclaimItem(_ item: FSItem) async throws {
        //todo rm zip archives. Mb use timers and debouncers
        logger.debug("reclaimItem: \(item)")
    }

    func readSymbolicLink(
        _ item: FSItem
    ) async throws -> FSFileName {
        logger.debug("readSymbolicLink: \(item)")
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
    }

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest
    ) async throws -> (FSItem, FSFileName) {
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)

        // logger.debug("createItem: \(String(describing: name.string)) - \(newAttributes.mode)")
        // guard let directory = directory as? FSItemProtocol else {
        //     throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        // }
        // let item = MyFSItem(name: name)
        // mergeAttributes(item.attributes, request: newAttributes)
        // item.attributes.parentID = directory.attributes.fileID
        // item.attributes.type = type
        // directory.addItem(item)

        // return (item, name)
    }

    func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName
    ) async throws -> (FSItem, FSFileName) {
        // let data = try Data(
        //     contentsOf: URL(
        //         filePath:
        //             "/Users/vadymh/Library/Containers/app.badim.FSKitExpExtension/data/deptree.json"
        //     ))

        // do {
        //     let json = try DependencyNode.fromJSONData(data)
        // } catch {
        //     logger.debug("Error parsing JSON: \(error)")
        // }
        // let depTree = try DependencyNode.fromJSONData(data)
        // let depFsNode = DependencyFSNode.buildTree(from: depTree)
        logger.debug("createSymbolicLink: \(name)")
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
    }

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> FSFileName {
        logger.debug("createLink: \(name)")
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem
    ) async throws {
        logger.debug("remove: \(name)")
        // if let item = item as? FSItemProtocol, let directory = directory as? FSItemProtocol {
        //     directory.removeItem(item)
        // } else {
        //     throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        // }
    }

    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?
    ) async throws -> FSFileName {
        logger.debug("rename: \(item)")
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
    }

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker
    ) async throws -> FSDirectoryVerifier {
        logger.debug("enumerateDirectory: \(directory)")

        guard let directory = directory as? FSItemProtocol else {
            throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
        }

        var idx = 0
        for (name, item) in try directory.getChildren() {
            if (idx < cookie.rawValue) {
                idx += 1
                continue
            }
            let attrs = try item.getAttributes()
            let ok = packer.packEntry(
                name: name,
                itemType: attrs.type,
                itemID: attrs.fileID,
                nextCookie: FSDirectoryCookie(UInt64(idx+1)),
                attributes: attributes != nil ? attrs : nil
            )
            if (!ok)  {
                // we stop iterating
                break
            }
            idx += 1
        }

        return FSDirectoryVerifier(0) //todo change 0 for mutations
    }

    private func mergeAttributes(
        _ existing: FSItem.Attributes, request: FSItem.SetAttributesRequest
    ) {
        if request.isValid(FSItem.Attribute.uid) {
            existing.uid = request.uid
        }

        if request.isValid(FSItem.Attribute.gid) {
            existing.gid = request.gid
        }

        if request.isValid(FSItem.Attribute.type) {
            existing.type = request.type
        }

        if request.isValid(FSItem.Attribute.mode) {
            existing.mode = request.mode
        }

        if request.isValid(FSItem.Attribute.linkCount) {
            existing.linkCount = request.linkCount
        }

        if request.isValid(FSItem.Attribute.flags) {
            existing.flags = request.flags
        }

        if request.isValid(FSItem.Attribute.size) {
            existing.size = request.size
        }

        if request.isValid(FSItem.Attribute.allocSize) {
            existing.allocSize = request.allocSize
        }

        if request.isValid(FSItem.Attribute.fileID) {
            existing.fileID = request.fileID
        }

        if request.isValid(FSItem.Attribute.parentID) {
            existing.parentID = request.parentID
        }

        if request.isValid(FSItem.Attribute.accessTime) {
            let timespec = timespec()
            request.accessTime = timespec
            existing.accessTime = timespec
        }

        if request.isValid(FSItem.Attribute.changeTime) {
            let timespec = timespec()
            request.changeTime = timespec
            existing.changeTime = timespec
        }

        if request.isValid(FSItem.Attribute.modifyTime) {
            let timespec = timespec()
            request.modifyTime = timespec
            existing.modifyTime = timespec
        }

        if request.isValid(FSItem.Attribute.addedTime) {
            let timespec = timespec()
            request.addedTime = timespec
            existing.addedTime = timespec
        }

        if request.isValid(FSItem.Attribute.birthTime) {
            let timespec = timespec()
            request.birthTime = timespec
            existing.birthTime = timespec
        }

        if request.isValid(FSItem.Attribute.backupTime) {
            let timespec = timespec()
            request.backupTime = timespec
            existing.backupTime = timespec
        }
    }
}

// extension MyFSVolume: FSVolume.OpenCloseOperations {

//     func openItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
//         if let item = item as? FSItemProtocol {
//             logger.debug("open: \(item.name)")
//         } else {
//             logger.debug("open: \(item)")
//         }
//     }

//     func closeItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
//         if let item = item as? FSItemProtocol {
//             logger.debug("close: \(item.name)")
//         } else {
//             logger.debug("close: \(item)")
//         }
//     }
// }

extension MyFSVolume: FSVolume.ReadWriteOperations {

    func read(
        from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer
    ) async throws -> Int {
        logger.debug("read: \(item)")


        guard let item = item as? FSItemProtocol else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        var bytesRead = 0

        return try item.readData(offset: offset, length: length, into: buffer)
            // bytesRead = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            //     let length = min(buffer.length, data.count)
            //     _ = buffer.withUnsafeMutableBytes { dst in
            //         memcpy(dst.baseAddress, ptr.baseAddress, length)
            //     }
            //     return length
            // }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        // logger.debug("write: \(item) - \(offset)")

        // if let item = item as? FSItemProtocol {
        //     logger.debug("- write: \(item.name)")
        //     item.data = contents
        //     item.attributes.size = UInt64(contents.count)
        //     item.attributes.allocSize = UInt64(contents.count)
        // }

        // return contents.count
    }
}

// extension MyFSVolume: FSVolume.XattrOperations {

//     func xattr(named name: FSFileName, of item: FSItem) async throws -> Data {
//         logger.debug("xattr: \(item) - \(name.string ?? "NA")")

//         if let item = item as? FSItemProtocol {
//             return item.xattrs[name] ?? Data()
//         } else {
//             return Data()
//         }
//     }

//     func setXattr(
//         named name: FSFileName, to value: Data?, on item: FSItem, policy: FSVolume.SetXattrPolicy
//     ) async throws {
//         logger.debug("setXattrOf: \(item)")

//         if let item = item as? FSItemProtocol {
//             item.xattrs[name] = value
//         }
//     }

//     func xattrs(of item: FSItem) async throws -> [FSFileName] {
//         logger.debug("listXattrs: \(item)")

//         if let item = item as? FSItemProtocol {
//             return Array(item.xattrs.keys)
//         } else {
//             return []
//         }
//     }
// }
