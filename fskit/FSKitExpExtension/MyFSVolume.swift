//
//  MyFSVolume.swift
//  FSKitExp
//
//  Created by Khaos Tian on 3/30/25.
//

import FSKit
import Foundation
import os


@available(macOS 15.4, *)
class MyFSItem: FSItem {
    let fileId: FSItem.Identifier
    init(fileId: FSItem.Identifier) {
        self.fileId = fileId
    }    
}

// extension FSItem.GetAttributesRequest {
//     var printRequestedAttributes: String {
//         var result = ""
//         let map = [
//             "type": FSItem.Attribute.type,
//             "mode": FSItem.Attribute.mode,
//             "linkCount": FSItem.Attribute.linkCount,
//             "uid": FSItem.Attribute.uid,
//             "gid": FSItem.Attribute.gid,
//             "flags": FSItem.Attribute.flags,
//             "size": FSItem.Attribute.size,
//             "allocSize": FSItem.Attribute.allocSize,
//             "fileID": FSItem.Attribute.fileID,
//             "parentID": FSItem.Attribute.parentID,
//             "accessTime": FSItem.Attribute.accessTime,
//             "modifyTime": FSItem.Attribute.modifyTime,
//             "changeTime": FSItem.Attribute.changeTime,
//             "birthTime": FSItem.Attribute.birthTime,
//             "backupTime": FSItem.Attribute.backupTime,
//             "addedTime": FSItem.Attribute.addedTime,
//             "supportsLimitedXAttrs": FSItem.Attribute.supportsLimitedXAttrs,
//             "inhibitKernelOffloadedIO": FSItem.Attribute.inhibitKernelOffloadedIO,
//         ]
//         for (key, value) in map {
//             if self.isAttributeWanted(value) {
//                 result += "\(key), "
//             }
//         }
//         return result
//     }
// }

// func readDirectoryEntriesUsingGetdirentries(fd: Int32) throws -> [(
//     name: String, type: FSItem.ItemType
// )] {
//     // try Filena.contentsOfDirectory
//     defer { close(fd) }

//     // Use a reasonably sized buffer for directory entries
//     let bufferSize = 8192
//     var buffer = [UInt8](repeating: 0, count: bufferSize)
//     var position: Int = 0
//     // var results = [(name: String, type: FSItem.ItemType)]()

//     while true {
//         // Call getdirentries to fill buffer with directory entries
//         let bytesRead = getdirentries(fd, &buffer, Int32(bufferSize), &position)

//         if bytesRead <= 0 {
//             if bytesRead < 0 {
//                 let error = errno
//                 // logger.error("getdirentries_b failed: \(error)")
//                 throw fs_errorForPOSIXError(error)
//             }
//             break  // No more entries
//         }

//     }

//     return results
// }

@available(macOS 15.4, *)
final class MyFSVolume: FSVolume {
    // var fd1: Int32 = -1
    var fd2: Int32 = -1
    private let resource: FSResource
    var urls: [URL?]?
    private var fs: FileSystem!
    var p: [URL?]?
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
// extension MyFSVolume: FSVolumeKernelOffloadedIOOperations
@available(macOS 15.4, *)
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

// extension MyFSVolume: FSVolume.ItemDeactivation {
//     var itemDeactivationPolicy: FSVolume.ItemDeactivationOptions {
//         return ItemDeactivationOptions.always
//     }
//     func deactivateItem(_ item: FSItem) async throws {
//         // logger.debug("deactivateItem: \(item)")
//     }
// }

@available(macOS 15.4, *)
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
        // fd2 = open("/Users/vadymh/github/fskit/FSKitSample/test", O_RDONLY | O_DIRECTORY, 0)
        // self.mount2 = options
        // self.fd2 = open("/Users/vadymh/github/fskit/FSKitSample/test2", O_RDONLY | O_DIRECTORY, 0)
        // if self.fd2 < 0 {
        //     let error = errno
        //     // logger.error("Failed to open directory: \(path), error: \(error)")
        //     throw fs_errorForPOSIXError(error)
        // }
        self.p = [
            options.url(forOption: "m"),
            options.url(forOption: "d"),
        ]

        // self.mount3 = options
        var path: String? = nil
        // path = "/Users/vadymh/github/fskit/FSKitSample/example/.yarn/fuse-state.json"
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
            self.fs = try FileSystem(manifestPath: path)
            // self.fs.
            return MyFSItem(fileId: .rootDirectory)

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
        logger.debug("mount")
    }

    func unmount() async {
        logger.debug("unmount")
    }

    func synchronize(flags: FSSyncFlags) async throws {
        // logger.debug("synchronize")
    }
    
    public func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes req: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        // replyHandler: @escaping (FSDirectoryVerifier, (any Error)?) -> Void
    ) async throws -> FSDirectoryVerifier {
        guard let directory = directory as? MyFSItem else {
            throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
        }
        return try await fs.enumerateDirectory(directory: directory.fileId, startingAt: cookie, verifier: verifier, attributes: req, packer: packer)
    }

    func attributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem
    ) async throws -> FSItem.Attributes {
        guard let item = item as? MyFSItem else {
            throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
        }
        return try await fs.getAttributes(desiredAttributes, of: item.fileId)
    }

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> (FSItem, FSFileName) {
        // logger.debug("lookupName: \(String(describing: name.string)), \(directory)")

        guard let directory = directory as? MyFSItem else {
            throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
        }

        let result = try await fs.lookupItem(name, inDirectory: directory.fileId)
        return (MyFSItem(fileId: result.0), result.1)
    }

    func reclaimItem(_ item: FSItem) async throws {
        // logger.debug("deactivateItem: \(item)")
        //todo rm zip archives. Mb use timers and debouncers
        // logger.debug("reclaimItem: \(item)")
    }

    func readSymbolicLink(
        _ item: FSItem
    ) async throws -> FSFileName {
        guard let item = item as? MyFSItem else {
            throw fs_errorForPOSIXError(POSIXError.ENOENT.rawValue)
        }
        return try await fs.readSymbolicLink(item.fileId)
    }


    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem
    ) async throws -> FSItem.Attributes {
        throw fs_errorForPOSIXError(POSIXError.EROFS.rawValue)
    }

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest
    ) async throws -> (FSItem, FSFileName) {
        throw fs_errorForPOSIXError(POSIXError.EROFS.rawValue)
    }

    func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName
    ) async throws -> (FSItem, FSFileName) {

        // let dirFD = dup(fd2)
        // if dirFD == -1 {
        //     throw fs_errorForPOSIXError(errno)
        // }
        // guard let dir = fdopendir(dirFD) else {
        //     close(dirFD)  // Close the duplicate if fdopendir fails
        //     throw fs_errorForPOSIXError(errno)
        // }
        // rewinddir(dir)

        // defer { closedir(dir) }

        // while let entry = readdir(dir) {
        //     // Get entry name
        //     let name = withUnsafePointer(to: entry.pointee.d_name) { ptr in
        //         String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        //     }

        //     // Skip . and ..
        //     if name == "." || name == ".." {
        //         continue
        //     }

        // }

        throw fs_errorForPOSIXError(POSIXError.EROFS.rawValue)

    }

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem
    ) async throws -> FSFileName {
        throw fs_errorForPOSIXError(POSIXError.EROFS.rawValue)
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem
    ) async throws {
        throw fs_errorForPOSIXError(POSIXError.EROFS.rawValue)
    }

    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?
    ) async throws -> FSFileName {
        throw fs_errorForPOSIXError(POSIXError.EROFS.rawValue)
    }

}

// extension MyFSVolume: FSVolume.OpenCloseOperations {

//     func openItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
//         if let item = item as? MyFSItem {
//             logger.debug("open: \(item.name)")
//         } else {
//             logger.debug("open: \(item)")
//         }
//     }

//     func closeItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
//         if let item = item as? MyFSItem {
//             logger.debug("close: \(item.name)")
//         } else {
//             logger.debug("close: \(item)")
//         }
//     }
// }

@available(macOS 15.4, *)
extension MyFSVolume: FSVolume.ReadWriteOperations {
    func read(
        from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer
    ) async throws -> Int {
        guard let item = item as? MyFSItem else {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        return try await fs.readData(item.fileId, offset: offset, length: length, into: buffer)
    }

    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        throw fs_errorForPOSIXError(POSIXError.EROFS.rawValue)
        // guard let item = item as? MyFSItem else {
        //     throw fs_errorForPOSIXError(POSIXError.EROFS.rawValue)
        // }
        // return try item.writeData(contents: contents, offset: offset)
    }
}
