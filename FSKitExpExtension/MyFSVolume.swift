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
    var urls: [URL?]?
    private var depTree: DependencyNode?
    var mount3: FSTaskOptions? = nil
    var mount2: FSTaskOptions? = nil

    private let logger = Logger(subsystem: "FSKitExp", category: "MyFSVolume")

    init(resource: FSResource) {
        self.resource = resource

        super.init(
            volumeID: FSVolume.Identifier(uuid: Constants.volumeIdentifier),
            volumeName: FSFileName(string: "Test1")
        )
    }
}
// extension MyFSVolume: FSVolumeKernelOffloadedIOOperations


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

extension MyFSVolume: FSVolume.ItemDeactivation {
    var itemDeactivationPolicy : FSVolume.ItemDeactivationOptions {
        return ItemDeactivationOptions.always
    }
    func deactivateItem(_ item: FSItem) async throws {
        // logger.debug("deactivateItem: \(item)")   
    }
}


extension MyFSVolume: FSVolume.Operations {

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        logger.debug("supportedVolumeCapabilities")

        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsHardLinks = true
        capabilities.supportsSymbolicLinks = true
        capabilities.supportsPersistentObjectIDs = true
        capabilities.supportsHiddenFiles = true  //??
        capabilities.supports64BitObjectIDs = true
        capabilities.caseFormat = .insensitiveCasePreserving

        capabilities.doesNotSupportVolumeSizes = true
        // capabilities.doesNotSupportImmutableFiles = true ??
        return capabilities
    }

    var volumeStatistics: FSStatFSResult {
        logger.debug("volumeStatistics")

        let result = FSStatFSResult(fileSystemTypeName: "MyFS")

        // result.blockSize = 1_024_000
        // result.ioSize = 1_024_000
        // result.totalBlocks = 1_024_000
        // result.availableBlocks = 1_024_000
        // result.freeBlocks = 1_024_000
        // result.totalFiles = 1_024_000
        // result.freeFiles = 1_024_000

        return result
    }

    func activate(options: FSTaskOptions) async throws -> FSItem {
        self.mount3 = options
        var path: String? = nil
        var optionsIter = options.taskOptions.makeIterator()
        while let option = optionsIter.next() {
            switch option {
            case "-m":
                path = optionsIter.next()
            default:
                throw MyError.badMountParams
            }
        }

        guard let path = path else {
            throw MyError.badMountParams
        }

        logger.debug("activate")

        do {
            let root = try {
                let data = try Data(contentsOf: URL(filePath: path))
                let depTree = try DependencyNode.fromJSONData(data)
                let depFsNode = DependencyFSNodeCreator().buildTree(from: depTree)
                return depFsNode
            }()
            return root

        } catch {
            logger.error("Error mounting: \(error)")
            throw error
        }
    }

    func deactivate(options: FSDeactivateOptions = []) async throws {
        // resource.revoke()
        logger.debug("deactivate")
    }

    func mount(options: FSTaskOptions) async throws {
        self.mount2 = options
        logger.debug("mount")
    }

    func unmount() async {
        logger.debug("unmount")
    }

    func synchronize(flags: FSSyncFlags) async throws {
        // logger.debug("synchronize")
    }

    func attributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem
    ) async throws -> FSItem.Attributes {
    
        if let item = item as? FSItemProtocol {
            return try item.getAttributes()
        } else {
            // logger.debug("getItemAttributes2: \(item), \(desiredAttributes)")
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem
    ) async throws -> FSItem.Attributes {
        guard let item = item as? WriteFSItemProtocol else {
            throw fs_errorForPOSIXError(POSIXError.EROFS.rawValue)
        }

        return try item.setAttributes(newAttributes: newAttributes)
    }

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> (FSItem, FSFileName) {
        // logger.debug("lookupName: \(String(describing: name.string)), \(directory)")

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
        // logger.debug("deactivateItem: \(item)")   
        //todo rm zip archives. Mb use timers and debouncers
        // logger.debug("reclaimItem: \(item)")
    }

    func readSymbolicLink(
        _ item: FSItem
    ) async throws -> FSFileName {
        guard let item = item as? FSItemProtocol else {
            throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
        }
        return try item.readSymbolicLink()
    }

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest
    ) async throws -> (FSItem, FSFileName) {
        guard let directory = directory as? WriteFSItemProtocol else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        return try directory.createItem(
            named: name,
            type: type,
            attributes: newAttributes
        )
    }

    func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName
    ) async throws -> (FSItem, FSFileName) {
        guard let directory = directory as? WriteFSItemProtocol else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        return try directory.createSymbolicLink(
            named: name,
            attributes: newAttributes,
            linkContents: contents
        )
    }

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> FSFileName {
        guard let item = item as? WriteFSItemProtocol else {  //todo rm hardlink support?
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        return try item.createLink(to: name, inDirectory: directory)
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem
    ) async throws {
        guard let item = item as? WriteFSItemProtocol else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        return try item.removeItem(name: name, fromDirectory: directory)
    }

    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?
    ) async throws -> FSFileName {
        guard let item = item as? WriteFSItemProtocol else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        return try item.renameItem(
            inDirectory: sourceDirectory,
            named: sourceName,
            to: destinationName,
            inDirectory: destinationDirectory,
            overItem: overItem
        )
    }

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes req: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker
    ) async throws -> FSDirectoryVerifier {

        guard let directory = directory as? FSItemProtocol else {
            throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
        }

        var idx = 0
        for (name, item) in try directory.getChildren() {
            if idx < cookie.rawValue {
                idx += 1
                continue
            }
            let attributes = req != nil ? try item.getAttributes() : nil  //todo requested attributes?
            let ok = packer.packEntry(
                name: name,
                itemType: item.itemType,
                itemID: item.fileId,
                nextCookie: FSDirectoryCookie(UInt64(idx + 1)),
                attributes: attributes,
            )

            if !ok {
                // fskit dont't want to continue
                break
            }
            idx += 1
        }

        return FSDirectoryVerifier(0)  //todo change 0 for mutations
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
        guard let item = item as? FSItemProtocol else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        return try item.readData(offset: offset, length: length, into: buffer)
    }

    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        guard let item = item as? WriteFSItemProtocol else {
            throw fs_errorForPOSIXError(POSIXError.EROFS.rawValue)
        }
        return try item.writeData(contents: contents, offset: offset)
    }
}
