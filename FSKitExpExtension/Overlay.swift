//
//  Overlay.swift
//  FSKitExp
//
//  Created by Vadym Holoveichuk on 04.04.2025.
//

import Foundation
import FSKit


protocol WriteFSItemProtocol: FSItemProtocol {
    func setAttributes(newAttributes: FSItem.SetAttributesRequest) throws -> FSItem.Attributes
    func writeData(contents: Data, offset: off_t) throws -> Int
    func removeItem(name: FSFileName, fromDirectory: FSItem) throws
    func createLink(to name: FSFileName, inDirectory: FSItem) throws -> FSFileName
    func renameItem(
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?) throws -> FSFileName

    func createSymbolicLink(
        named name: FSFileName,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName
    ) throws -> (FSItem, FSFileName)

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        
        attributes newAttributes: FSItem.SetAttributesRequest
    ) throws -> (FSItem, FSFileName)

}

class OverlayFileItem: FSItem {
    let lower: FSItemProtocol

    init(lower: FSItemProtocol) {
        self.lower = lower
    }

    // let itemType: FSItem.ItemType
    // let itemID: FSItem.Identifier
}

class OverlayDirItem: FSItem {

}



/// Represents a file or directory in the overlayfs
class OverlayItem2: FSItem {
    // Path in the upper layer, if exists
    var upperPath: String?
    
    // Path in the lower layer
    var lowerPath: String
    
    // Item type
    let itemType: FSItem.ItemType
    
    // Item identifier
    let itemID: FSItem.Identifier
    
    // Indicates if this item exists in the upper layer
    var existsInUpper: Bool {
        return upperPath != nil
    }
    
    init(lowerPath: String, upperPath: String?, itemType: FSItem.ItemType, itemID: FSItem.Identifier) {
        self.lowerPath = lowerPath
        self.upperPath = upperPath
        self.itemType = itemType
        self.itemID = itemID
        super.init()
    }
    
    // Returns the most relevant path (upper if exists, otherwise lower)
    var effectivePath: String {
        return upperPath ?? lowerPath
    }
    
    // Creates upper path if it doesn't exist yet (for copy-up operations)
    func ensureUpperPath(in upperDir: URL) -> Bool {
        guard upperPath == nil else { return true }
        
        let lowerURL = URL(fileURLWithPath: lowerPath)
        let fileName = lowerURL.lastPathComponent
        let upperURL = upperDir.appendingPathComponent(fileName)
        
        upperPath = upperURL.path
        return true
    }
}


// class OverlayVolume: FSVolume {
//     // Paths for lower and upper directories
//     private let lowerDirURL: URL
//     private let upperDirURL: URL
    
//     // Root item cache
//     private var rootItem: OverlayItem?
    
//     // Thread safety
//     private let lock = NSLock()
    
//     // Logger
//     private let logger = Logger(subsystem: "com.example.FSKitExp", category: "OverlayFS")
    
//     // Cache for items to improve performance
//     private var itemCache = [FSItem.Identifier: OverlayItem]()
    
//     init(volumeID: FSVolume.Identifier, volumeName: FSFileName, lowerDir: URL, upperDir: URL) {
//         self.lowerDirURL = lowerDir
//         self.upperDirURL = upperDir
        
//         super.init(volumeID: volumeID, volumeName: volumeName)
        
//         // Create upper directory if it doesn't exist
//         try? FileManager.default.createDirectory(at: upperDir, withIntermediateDirectories: true)
//     }
    
//     // Helper method to perform copy-up operation from lower to upper
//     private func copyUp(item: OverlayItem) throws {
//         guard !item.existsInUpper else { return }
        
//         let lowerPath = item.lowerPath
//         guard item.ensureUpperPath(in: upperDirURL) else {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: nil)
//         }
        
//         guard let upperPath = item.upperPath else {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: nil)
//         }
        
//         if item.itemType == .directory {
//             try FileManager.default.createDirectory(atPath: upperPath, withIntermediateDirectories: true)
//         } else {
//             // Use low-level syscalls for file copying
//             let lowerFD = Darwin.open(lowerPath, O_RDONLY)
//             if lowerFD == -1 {
//                 throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//             }
//             defer { Darwin.close(lowerFD) }
            
//             let upperFD = Darwin.open(upperPath, O_WRONLY | O_CREAT, 0o644)
//             if upperFD == -1 {
//                 throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//             }
//             defer { Darwin.close(upperFD) }
            
//             var buffer = [UInt8](repeating: 0, count: 65536)
//             var bytesRead: Int
            
//             repeat {
//                 bytesRead = Darwin.read(lowerFD, &buffer, buffer.count)
//                 if bytesRead > 0 {
//                     let bytesWritten = Darwin.write(upperFD, buffer, bytesRead)
//                     if bytesWritten != bytesRead {
//                         throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: nil)
//                     }
//                 }
//             } while bytesRead > 0
            
//             if bytesRead == -1 {
//                 throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//             }
//         }
        
//         // Copy attributes
//         var stat = stat()
//         if Darwin.stat(lowerPath, &stat) == 0 {
//             Darwin.chmod(upperPath, stat.st_mode & 0o777)
            
//             let times = [timespec(tv_sec: stat.st_atimespec.tv_sec, tv_nsec: stat.st_atimespec.tv_nsec),
//                          timespec(tv_sec: stat.st_mtimespec.tv_sec, tv_nsec: stat.st_mtimespec.tv_nsec)]
//             Darwin.utimensat(AT_FDCWD, upperPath, times, 0)
//         }
//     }
    
//     // Helper to check if a file exists in either layer
//     private func fileExists(at path: String, isDirectory: inout Bool) -> Bool {
//         var statBuf = stat()
//         guard Darwin.stat(path, &statBuf) == 0 else {
//             return false
//         }
        
//         isDirectory = (statBuf.st_mode & S_IFDIR) != 0
//         return true
//     }
    
//     // Create a new item identifier
//     private func createItemIdentifier() -> FSItem.Identifier {
//         return FSItem.Identifier(UInt64(arc4random_uniform(UInt32.max)) << 32 + UInt64(arc4random_uniform(UInt32.max)))
//     }
// }

// // MARK: - FSVolume.PathConfOperations Implementation

// // MARK: - FSVolume.Operations Implementation

// extension OverlayVolume: FSVolume.Operations {
  
//     var volumeStatistics: FSStatFSResult {
//         // Get stats from upper directory as that's where we write
//         let result = FSStatFSResult(fileSystemTypeName: "overlayfs")
        
//         var statfs = Darwin.statfs()
//         if Darwin.statfs(upperDirURL.path, &statfs) == 0 {
//             result.blockSize = Int(statfs.f_bsize)
//             result.ioSize = Int(statfs.f_iosize)
//             result.totalBlocks = UInt64(statfs.f_blocks)
//             result.availableBlocks = UInt64(statfs.f_bavail)
//             result.freeBlocks = UInt64(statfs.f_bfree)
//             result.totalFiles = UInt64(statfs.f_files)
//             result.freeFiles = UInt64(statfs.f_ffree)
            
//             // Calculate used blocks
//             result.usedBlocks = result.totalBlocks - result.freeBlocks
            
//             // Calculate byte values
//             let blockSize = UInt64(statfs.f_bsize)
//             result.totalBytes = result.totalBlocks * blockSize
//             result.availableBytes = result.availableBlocks * blockSize
//             result.freeBytes = result.freeBlocks * blockSize
//             result.usedBytes = result.usedBlocks * blockSize
//         } else {
//             // Default values if statfs fails
//             result.blockSize = 4096
//             result.ioSize = 4096
//         }
        
//         return result
//     }
    
//     func mount(options: FSTaskOptions) async throws {
//         logger.info("Mounting OverlayFS volume")
//         // Nothing special needed for mount - activation already set up the filesystem
//     }
    
//     func mount(options: FSTaskOptions, replyHandler reply: @escaping ((Error)?) -> Void) {
//         reply(nil)
//     }
    
//     func unmount() async {
//         logger.info("Unmounting OverlayFS volume")
//         // Clear any caches
//         lock.lock()
//         itemCache.removeAll()
//         rootItem = nil
//         lock.unlock()
//     }
    
//     func unmount(replyHandler reply: @escaping () -> Void) {
//         lock.lock()
//         itemCache.removeAll()
//         rootItem = nil
//         lock.unlock()
//         reply()
//     }
    
//     func synchronize(flags: FSSyncFlags) async throws {
//         // Sync is a no-op since we're using the real filesystem which handles syncing
//     }
    
//     func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((Error)?) -> Void) {
//         reply(nil)
//     }
    
//     func attributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem) async throws -> FSItem.Attributes {
//         guard let overlayItem = item as? OverlayItem else {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: nil)
//         }
        
//         let path = overlayItem.effectivePath
//         var statBuf = stat()
        
//         if Darwin.stat(path, &statBuf) != 0 {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//         }
        
//         let attributes = FSItem.Attributes()
        
//         if desiredAttributes.wantedAttributes.contains(.regularAttributes) {
//             attributes.ownerID = statBuf.st_uid
//             attributes.groupID = statBuf.st_gid
//             attributes.permissions = UInt16(statBuf.st_mode & 0o777)
//             attributes.linkCount = UInt32(statBuf.st_nlink)
//             attributes.size = UInt64(statBuf.st_size)
//             attributes.blockCount = UInt64(statBuf.st_blocks)
//             attributes.blockSize = UInt32(statBuf.st_blksize)
            
//             let createTime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_birthtimespec.tv_sec) + TimeInterval(statBuf.st_birthtimespec.tv_nsec) / 1_000_000_000)
//             let modifyTime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_mtimespec.tv_sec) + TimeInterval(statBuf.st_mtimespec.tv_nsec) / 1_000_000_000)
//             let accessTime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_atimespec.tv_sec) + TimeInterval(statBuf.st_atimespec.tv_nsec) / 1_000_000_000)
//             let changeTime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_ctimespec.tv_sec) + TimeInterval(statBuf.st_ctimespec.tv_nsec) / 1_000_000_000)
            
//             attributes.createTime = createTime
//             attributes.contentModificationTime = modifyTime
//             attributes.accessTime = accessTime
//             attributes.attributeModificationTime = changeTime
//         }
        
//         return attributes
//     }
    
//     func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem, replyHandler reply: @escaping (FSItem.Attributes?, (Error)?) -> Void) {
//         Task {
//             do {
//                 let attrs = try await attributes(desiredAttributes, of: item)
//                 reply(attrs, nil)
//             } catch {
//                 reply(nil, error)
//             }
//         }
//     }
    
//     func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
//         guard let overlayItem = item as? OverlayItem else {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: nil)
//         }
        
//         // Need to ensure file exists in upper layer before modifying attributes
//         if !overlayItem.existsInUpper {
//             try copyUp(item: overlayItem)
//         }
        
//         guard let upperPath = overlayItem.upperPath else {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: nil)
//         }
        
//         if let size = newAttributes.size {
//             // Set file size using truncate
//             if Darwin.truncate(upperPath, off_t(size)) != 0 {
//                 throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//             }
//         }
        
//         if let permissions = newAttributes.permissions {
//             // Set permissions using chmod
//             if Darwin.chmod(upperPath, mode_t(permissions)) != 0 {
//                 throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//             }
//         }
        
//         if let ownerID = newAttributes.ownerID, let groupID = newAttributes.groupID {
//             // Set owner and group using chown
//             if Darwin.chown(upperPath, uid_t(ownerID), gid_t(groupID)) != 0 {
//                 throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//             }
//         }
        
//         // Set times if needed
//         if newAttributes.accessTime != nil || newAttributes.contentModificationTime != nil {
//             var times: [timespec] = [timespec(), timespec()]
            
//             if let atime = newAttributes.accessTime {
//                 let seconds = atime.timeIntervalSince1970
//                 times[0].tv_sec = Int(seconds)
//                 times[0].tv_nsec = Int((seconds - Double(times[0].tv_sec)) * 1_000_000_000)
//             } else {
//                 times[0].tv_nsec = UTIME_OMIT
//             }
            
//             if let mtime = newAttributes.contentModificationTime {
//                 let seconds = mtime.timeIntervalSince1970
//                 times[1].tv_sec = Int(seconds)
//                 times[1].tv_nsec = Int((seconds - Double(times[1].tv_sec)) * 1_000_000_000)
//             } else {
//                 times[1].tv_nsec = UTIME_OMIT
//             }
            
//             if Darwin.utimensat(AT_FDCWD, upperPath, times, 0) != 0 {
//                 throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//             }
//         }
        
//         // Return updated attributes
//         return try await attributes(FSItem.GetAttributesRequest(wantedAttributes: [.regularAttributes]), of: item)
//     }
    
//     func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem, replyHandler reply: @escaping (FSItem.Attributes?, (Error)?) -> Void) {
//         Task {
//             do {
//                 let attrs = try await setAttributes(newAttributes, on: item)
//                 reply(attrs, nil)
//             } catch {
//                 reply(nil, error)
//             }
//         }
//     }
    
//     func lookupItem(named name: FSFileName, inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
//         guard let overlayDir = directory as? OverlayItem else {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: nil)
//         }
        
//         let nameStr = name.description
        
//         // Check in upper directory first
//         if let upperDirPath = overlayDir.upperPath {
//             let upperFilePath = URL(fileURLWithPath: upperDirPath).appendingPathComponent(nameStr).path
//             var isDir = false
//             if fileExists(at: upperFilePath, isDirectory: &isDir) {
//                 // Found in upper layer
//                 let itemType: FSItem.ItemType = isDir ? .directory : .file
//                 let itemID = createItemIdentifier()
                
//                 // Get the corresponding lower path even if file doesn't exist there
//                 let lowerFilePath = URL(fileURLWithPath: overlayDir.lowerPath).appendingPathComponent(nameStr).path
                
//                 let item = OverlayItem(lowerPath: lowerFilePath, upperPath: upperFilePath, 
//                                      itemType: itemType, itemID: itemID)
                
//                 lock.lock()
//                 itemCache[itemID] = item
//                 lock.unlock()
                
//                 return (item, name)
//             }
//         }
        
//         // If not found in upper, check lower directory
//         let lowerFilePath = URL(fileURLWithPath: overlayDir.lowerPath).appendingPathComponent(nameStr).path
//         var isDir = false
//         if fileExists(at: lowerFilePath, isDirectory: &isDir) {
//             // Found in lower layer
//             let itemType: FSItem.ItemType = isDir ? .directory : .file
//             let itemID = createItemIdentifier()
            
//             let item = OverlayItem(lowerPath: lowerFilePath, upperPath: nil, 
//                                  itemType: itemType, itemID: itemID)
            
//             lock.lock()
//             itemCache[itemID] = item
//             lock.unlock()
            
//             return (item, name)
//         }
        
//         // Not found in either layer
//         throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: nil)
//     }
    
//     func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping (FSItem?, FSFileName?, (Error)?) -> Void) {
//         Task {
//             do {
//                 let (item, fileName) = try await lookupItem(named: name, inDirectory: directory)
//                 reply(item, fileName, nil)
//             } catch {
//                 reply(nil, nil, error)
//             }
//         }
//     }
    
//     func reclaimItem(_ item: FSItem) async throws {
//         guard let overlayItem = item as? OverlayItem,
//               let itemID = overlayItem.itemID as? FSItem.Identifier else {
//             return
//         }
        
//         lock.lock()
//         itemCache.removeValue(forKey: itemID)
//         lock.unlock()
//     }
    
//     func reclaimItem(_ item: FSItem, replyHandler reply: @escaping ((Error)?) -> Void) {
//         Task {
//             do {
//                 try await reclaimItem(item)
//                 reply(nil)
//             } catch {
//                 reply(error)
//             }
//         }
//     }
    
//     func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
//         guard let overlayItem = item as? OverlayItem else {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: nil)
//         }
        
//         let path = overlayItem.effectivePath
//         let bufferSize = Int(PATH_MAX)
//         var buffer = [CChar](repeating: 0, count: bufferSize)
        
//         if Darwin.readlink(path, &buffer, bufferSize) == -1 {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//         }
        
//         let linkTarget = String(cString: buffer)
//         return FSFileName(linkTarget)
//     }
    
//     func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping (FSFileName?, (Error)?) -> Void) {
//         Task {
//             do {
//                 let linkTarget = try await readSymbolicLink(item)
//                 reply(linkTarget, nil)
//             } catch {
//                 reply(nil, error)
//             }
//         }
//     }
    
//     func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
//         guard let overlayDir = directory as? OverlayItem else {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: nil)
//         }
        
//         // Ensure parent directory exists in upper layer
//         if !overlayDir.existsInUpper {
//             try copyUp(item: overlayDir)
//         }
        
//         guard let upperDirPath = overlayDir.upperPath else {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: nil)
//         }
        
//         let nameStr = name.description
//         let upperPath = URL(fileURLWithPath: upperDirPath).appendingPathComponent(nameStr).path
        
//         // Check if file already exists in upper layer
//         var isDir = false
//         if fileExists(at: upperPath, isDirectory: &isDir) {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST), userInfo: nil)
//         }
        
//         // Create the item in upper layer
//         if type == .directory {
//             if Darwin.mkdir(upperPath, 0o755) != 0 {
//                 throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//             }
//         } else {
//             let fd = Darwin.open(upperPath, O_CREAT | O_RDWR, 0o644)
//             if fd == -1 {
//                 throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//             }
//             Darwin.close(fd)
//         }
        
//         // Create corresponding lower path (even though file doesn't exist there)
//         let lowerPath = URL(fileURLWithPath: overlayDir.lowerPath).appendingPathComponent(nameStr).path
        
//         // Create new item
//         let itemID = createItemIdentifier()
//         let item = OverlayItem(lowerPath: lowerPath, upperPath: upperPath, 
//                              itemType: type, itemID: itemID)
        
//         // Apply attributes if any
//         if !newAttributes.isEmpty {
//             _ = try await setAttributes(newAttributes, on: item)
//         }
        
//         // Cache the item
//         lock.lock()
//         itemCache[itemID] = item
//         lock.unlock()
        
//         return (item, name)
//     }
    
//     func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, replyHandler reply: @escaping (FSItem?, FSFileName?, (Error)?) -> Void) {
//         Task {
//             do {
//                 let (item, fileName) = try await createItem(named: name, type: type, inDirectory: directory, attributes: newAttributes)
//                 reply(item, fileName, nil)
//             } catch {
//                 reply(nil, nil, error)
//             }
//         }
//     }
    
//     func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) {
//         guard let overlayDir = directory as? OverlayItem else {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: nil)
//         }
        
//         // Ensure parent directory exists in upper layer
//         if !overlayDir.existsInUpper {
//             try copyUp(item: overlayDir)
//         }
        
//         guard let upperDirPath = overlayDir.upperPath else {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: nil)
//         }
        
//         let nameStr = name.description
//         let upperPath = URL(fileURLWithPath: upperDirPath).appendingPathComponent(nameStr).path
        
//         // Check if file already exists
//         var isDir = false
//         if fileExists(at: upperPath, isDirectory: &isDir) {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST), userInfo: nil)
//         }
        
//         // Create the symlink
//         if Darwin.symlink(contents.description, upperPath) != 0 {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//         }
        
//         // Create corresponding lower path (even though file doesn't exist there)
//         let lowerPath = URL(fileURLWithPath: overlayDir.lowerPath).appendingPathComponent(nameStr).path
        
//         // Create new item
//         let itemID = createItemIdentifier()
//         let item = OverlayItem(lowerPath: lowerPath, upperPath: upperPath, 
//                              itemType: .symlink, itemID: itemID)
        
//         // Apply attributes if any
//         if !newAttributes.isEmpty {
//             _ = try await setAttributes(newAttributes, on: item)
//         }
        
//         // Cache the item
//         lock.lock()
//         itemCache[itemID] = item
//         lock.unlock()
        
//         return (item, name)
//     }
    
//     func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName, replyHandler reply: @escaping (FSItem?, FSFileName?, (Error)?) -> Void) {
//         Task {
//             do {
//                 let (item, fileName) = try await createSymbolicLink(named: name, inDirectory: directory, attributes: newAttributes, linkContents: contents)
//                 reply(item, fileName, nil)
//             } catch {
//                 reply(nil, nil, error)
//             }
//         }
//     }
    
//     func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem) async throws -> FSFileName {
//         // Hard links not implemented for simplicity
//         throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP), userInfo: nil)
//     }
    
//     func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping (FSFileName?, (Error)?) -> Void) {
//         reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP), userInfo: nil))
//     }
    
//     func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws {
//         guard let overlayDir = directory as? OverlayItem,
//               let overlayItem = item as? OverlayItem else {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: nil)
//         }
        
//         let nameStr = name.description
        
//         // If the item exists in the lower layer, we need to create a "whiteout" in the upper layer
//         // In this implementation, we'll just create the item in the upper layer (if not already there)
//         // and then remove it, marking it as deleted
        
//         if overlayItem.existsInUpper {
//             // Item exists in upper layer, just remove it
//             guard let upperPath = overlayItem.upperPath else {
//                 throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: nil)
//             }
            
//             if overlayItem.itemType == .directory {
//                 if Darwin.rmdir(upperPath) != 0 {
//                     throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//                 }
//             } else {
//                 if Darwin.unlink(upperPath) != 0 {
//                     throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//                 }
//             }
//         } else if overlayDir.existsInUpper {
//             // Item exists only in lower layer, create a whiteout in upper layer
//             // For a real overlayfs implementation, we would use a special whiteout device
//             // Here we'll use a simpler approach - create a special marker file
//             guard let upperDirPath = overlayDir.upperPath else {
//                 throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: nil)
//             }
            
//             let whiteoutPath = URL(fileURLWithPath: upperDirPath)
//                 .appendingPathComponent(".__whiteout__.\(nameStr)").path
            
//             let fd = Darwin.open(whiteoutPath, O_CREAT | O_RDWR, 0o644)
//             if fd == -1 {
//                 throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//             }
//             Darwin.close(fd)
//         } else {
//             // Parent directory doesn't exist in upper layer yet, copy it up first
//             try copyUp(item: overlayDir)
            
//             // Then create the whiteout
//             guard let upperDirPath = overlayDir.upperPath else {
//                 throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: nil)
//             }
            
//             let whiteoutPath = URL(fileURLWithPath: upperDirPath)
//                 .appendingPathComponent(".__whiteout__.\(nameStr)").path
            
//             let fd = Darwin.open(whiteoutPath, O_CREAT | O_RDWR, 0o644)
//             if fd == -1 {
//                 throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//             }
//             Darwin.close(fd)
//         }
        
//         // Remove from cache
//         if let itemID = overlayItem.itemID as? FSItem.Identifier {
//             lock.lock()
//             itemCache.removeValue(forKey: itemID)
//             lock.unlock()
//         }
//     }
    
//     func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem, replyHandler reply: @escaping ((Error)?) -> Void) {
//         Task {
//             do {
//                 try await removeItem(item, named: name, fromDirectory: directory)
//                 reply(nil)
//             } catch {
//                 reply(error)
//             }
//         }
//     }
    
//     func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?) async throws -> FSFileName {
//         guard let overlayItem = item as? OverlayItem,
//               let sourceDir = sourceDirectory as? OverlayItem,
//               let destDir = destinationDirectory as? OverlayItem else {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: nil)
//         }
        
//         // Ensure source item exists in upper layer (copy up if needed)
//         if !overlayItem.existsInUpper {
//             try copyUp(item: overlayItem)
//         }
        
//         // Ensure both source and destination directories exist in upper layer
//         if !sourceDir.existsInUpper {
//             try copyUp(item: sourceDir)
//         }
        
//         if !destDir.existsInUpper {
//             try copyUp(item: destDir)
//         }
        
//         guard let upperSourceDirPath = sourceDir.upperPath,
//               let upperDestDirPath = destDir.upperPath,
//               let upperSourcePath = overlayItem.upperPath else {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: nil)
//         }
        
//         let sourceNameStr = sourceName.description
//         let destNameStr = destinationName.description
        
//         let upperDestPath = URL(fileURLWithPath: upperDestDirPath).appendingPathComponent(destNameStr).path
        
//         // Remove destination if it exists and overItem is provided
//         if let overItem = overItem as? OverlayItem, overItem.existsInUpper {
//             guard let upperOverPath = overItem.upperPath else {
//                 throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: nil)
//             }
            
//             if overItem.itemType == .directory {
//                 // Check if directory is empty
//                 let dirents = try FileManager.default.contentsOfDirectory(atPath: upperOverPath)
//                 if !dirents.isEmpty {
//                     throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTEMPTY), userInfo: nil)
//                 }
                
//                 if Darwin.rmdir(upperOverPath) != 0 {
//                     throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//                 }
//             } else {
//                 if Darwin.unlink(upperOverPath) != 0 {
//                     throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//                 }
//             }
//         }
        
//         // Perform the rename
//         if Darwin.rename(upperSourcePath, upperDestPath) != 0 {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//         }
        
//         // Update the item paths
//         overlayItem.upperPath = upperDestPath
        
//         // Also update the corresponding lower path
//         let lowerDestPath = URL(fileURLWithPath: destDir.lowerPath).appendingPathComponent(destNameStr).path
//         overlayItem.lowerPath = lowerDestPath
        
//         return destinationName
//     }
    
//     func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?, replyHandler reply: @escaping (FSFileName?, (Error)?) -> Void) {
//         Task {
//             do {
//                 let newName = try await renameItem(item, inDirectory: sourceDirectory, named: sourceName, to: destinationName, inDirectory: destinationDirectory, overItem: overItem)
//                 reply(newName, nil)
//             } catch {
//                 reply(nil, error)
//             }
//         }
//     }
    
//     func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier {
//         guard let overlayDir = directory as? OverlayItem else {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: nil)
//         }
        
//         // If this is the initial cookie, start enumeration from scratch
//         if cookie == .initial {
//             let lowerDirPath = overlayDir.lowerPath
//             var upperDirPath: String? = overlayDir.upperPath
            
//             // Keep track of files we've seen so we don't return duplicates
//             var seenFiles = Set<String>()
//             var nextCookie = FSDirectoryCookie(1)
            
//             // If attributes is nil, we need to add "." and ".." entries
//             if attributes == nil {
//                 // Add "." entry
//                 let itemID = createItemIdentifier()
//                 if !packer.packEntry(name: FSFileName("."), itemType: .directory, 
//                                     itemID: itemID, nextCookie: nextCookie, attributes: nil) {
//                     // If packing failed, stop enumeration
//                     return FSDirectoryVerifier(1)
//                 }
                
//                 nextCookie = FSDirectoryCookie(nextCookie.rawValue + 1)
                
//                 // Add ".." entry
//                 let parentID = createItemIdentifier()
//                 if !packer.packEntry(name: FSFileName(".."), itemType: .directory, 
//                                     itemID: parentID, nextCookie: nextCookie, attributes: nil) {
//                     // If packing failed, stop enumeration
//                     return FSDirectoryVerifier(1)
//                 }
                
//                 nextCookie = FSDirectoryCookie(nextCookie.rawValue + 1)
//             }
            
//             // First enumerate upper directory if it exists
//             if let upperPath = upperDirPath {
//                 do {
//                     let fileManager = FileManager.default
//                     let upperEntries = try fileManager.contentsOfDirectory(atPath: upperPath)
                    
//                     for entryName in upperEntries {
//                         // Skip whiteout marker files
//                         if entryName.hasPrefix(".__whiteout__.") {
//                             let hiddenFileName = String(entryName.dropFirst(".__whiteout__.".count))
//                             seenFiles.insert(hiddenFileName)
//                             continue
//                         }
                        
//                         seenFiles.insert(entryName)
                        
//                         let entryPath = URL(fileURLWithPath: upperPath).appendingPathComponent(entryName).path
//                         var isDir = false
//                         if fileExists(at: entryPath, isDirectory: &isDir) {
//                             let itemType: FSItem.ItemType = isDir ? .directory : .file
//                             let itemID = createItemIdentifier()
                            
//                             // Get attributes if requested
//                             var itemAttrs: FSItem.Attributes? = nil
//                             if let attrRequest = attributes {
//                                 var statBuf = stat()
//                                 if Darwin.stat(entryPath, &statBuf) == 0 {
//                                     itemAttrs = FSItem.Attributes()
                                    
//                                     if attrRequest.wantedAttributes.contains(.regularAttributes) {
//                                         itemAttrs?.ownerID = statBuf.st_uid
//                                         itemAttrs?.groupID = statBuf.st_gid
//                                         itemAttrs?.permissions = UInt16(statBuf.st_mode & 0o777)
//                                         itemAttrs?.linkCount = UInt32(statBuf.st_nlink)
//                                         itemAttrs?.size = UInt64(statBuf.st_size)
//                                         itemAttrs?.blockCount = UInt64(statBuf.st_blocks)
//                                         itemAttrs?.blockSize = UInt32(statBuf.st_blksize)
                                        
//                                         let createTime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_birthtimespec.tv_sec) + TimeInterval(statBuf.st_birthtimespec.tv_nsec) / 1_000_000_000)
//                                         let modifyTime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_mtimespec.tv_sec) + TimeInterval(statBuf.st_mtimespec.tv_nsec) / 1_000_000_000)
//                                         let accessTime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_atimespec.tv_sec) + TimeInterval(statBuf.st_atimespec.tv_nsec) / 1_000_000_000)
//                                         let changeTime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_ctimespec.tv_sec) + TimeInterval(statBuf.st_ctimespec.tv_nsec) / 1_000_000_000)
                                        
//                                         itemAttrs?.createTime = createTime
//                                         itemAttrs?.contentModificationTime = modifyTime
//                                         itemAttrs?.accessTime = accessTime
//                                         itemAttrs?.attributeModificationTime = changeTime
//                                     }
//                                 }
//                             }
                            
//                             if !packer.packEntry(name: FSFileName(entryName), itemType: itemType, 
//                                                itemID: itemID, nextCookie: nextCookie, attributes: itemAttrs) {
//                                 // If packing failed, stop enumeration and return current verifier
//                                 return FSDirectoryVerifier(1)
//                             }
                            
//                             nextCookie = FSDirectoryCookie(nextCookie.rawValue + 1)
//                         }
//                     }
//                 } catch {
//                     // Ignore errors reading upper directory
//                 }
//             }
            
//             // Then enumerate lower directory and add entries not already seen in upper
//             do {
//                 let fileManager = FileManager.default
//                 let lowerEntries = try fileManager.contentsOfDirectory(atPath: lowerDirPath)
                
//                 for entryName in lowerEntries {
//                     // Skip if we've already seen this file in the upper layer
//                     if seenFiles.contains(entryName) {
//                         continue
//                     }
                    
//                     let entryPath = URL(fileURLWithPath: lowerDirPath).appendingPathComponent(entryName).path
//                     var isDir = false
//                     if fileExists(at: entryPath, isDirectory: &isDir) {
//                         let itemType: FSItem.ItemType = isDir ? .directory : .file
//                         let itemID = createItemIdentifier()
                        
//                         // Get attributes if requested
//                         var itemAttrs: FSItem.Attributes? = nil
//                         if let attrRequest = attributes {
//                             var statBuf = stat()
//                             if Darwin.stat(entryPath, &statBuf) == 0 {
//                                 itemAttrs = FSItem.Attributes()
                                
//                                 if attrRequest.wantedAttributes.contains(.regularAttributes) {
//                                     itemAttrs?.ownerID = statBuf.st_uid
//                                     itemAttrs?.groupID = statBuf.st_gid
//                                     itemAttrs?.permissions = UInt16(statBuf.st_mode & 0o777)
//                                     itemAttrs?.linkCount = UInt32(statBuf.st_nlink)
//                                     itemAttrs?.size = UInt64(statBuf.st_size)
//                                     itemAttrs?.blockCount = UInt64(statBuf.st_blocks)
//                                     itemAttrs?.blockSize = UInt32(statBuf.st_blksize)
                                    
//                                     let createTime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_birthtimespec.tv_sec) + TimeInterval(statBuf.st_birthtimespec.tv_nsec) / 1_000_000_000)
//                                     let modifyTime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_mtimespec.tv_sec) + TimeInterval(statBuf.st_mtimespec.tv_nsec) / 1_000_000_000)
//                                     let accessTime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_atimespec.tv_sec) + TimeInterval(statBuf.st_atimespec.tv_nsec) / 1_000_000_000)
//                                     let changeTime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_ctimespec.tv_sec) + TimeInterval(statBuf.st_ctimespec.tv_nsec) / 1_000_000_000)
                                    
//                                     itemAttrs?.createTime = createTime
//                                     itemAttrs?.contentModificationTime = modifyTime
//                                     itemAttrs?.accessTime = accessTime
//                                     itemAttrs?.attributeModificationTime = changeTime
//                                 }
//                             }
//                         }
                        
//                         if !packer.packEntry(name: FSFileName(entryName), itemType: itemType, 
//                                            itemID: itemID, nextCookie: nextCookie, attributes: itemAttrs) {
//                             // If packing failed, stop enumeration and return current verifier
//                             return FSDirectoryVerifier(1)
//                         }
                        
//                         nextCookie = FSDirectoryCookie(nextCookie.rawValue + 1)
//                     }
//                 }
//             } catch {
//                 // Ignore errors reading lower directory
//             }
            
//             // Return new verifier
//             return FSDirectoryVerifier(1)
//         } else {
//             // Non-initial cookies not supported in this simple implementation
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: nil)
//         }
//     }
    
//     func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, replyHandler reply: @escaping (FSDirectoryVerifier, (Error)?) -> Void) {
//         Task {
//             do {
//                 let newVerifier = try await enumerateDirectory(directory, startingAt: cookie, verifier: verifier, attributes: attributes, packer: packer)
//                 reply(newVerifier, nil)
//             } catch {
//                 reply(verifier, error)
//             }
//         }
//     }
    
//     func activate(options: FSTaskOptions) async throws -> FSItem {
//         logger.info("Activating OverlayFS volume")
        
//         // Create the root item
//         let rootID = createItemIdentifier()
//         let root = OverlayItem(lowerPath: lowerDirURL.path, 
//                               upperPath: upperDirURL.path, 
//                               itemType: .directory, 
//                               itemID: rootID)
        
//         lock.lock()
//         rootItem = root
//         itemCache[rootID] = root
//         lock.unlock()
        
//         return root
//     }
    
//     func activate(options: FSTaskOptions, replyHandler reply: @escaping (FSItem?, (Error)?) -> Void) {
//         Task {
//             do {
//                 let rootItem = try await activate(options: options)
//                 reply(rootItem, nil)
//             } catch {
//                 reply(nil, error)
//             }
//         }
//     }
    
//     func deactivate(options: FSDeactivateOptions = []) async throws {
//         logger.info("Deactivating OverlayFS volume")
        
//         // Clear all caches
//         lock.lock()
//         itemCache.removeAll()
//         rootItem = nil
//         lock.unlock()
//     }
    
//     func deactivate(options: FSDeactivateOptions = [], replyHandler reply: @escaping ((Error)?) -> Void) {
//         lock.lock()
//         itemCache.removeAll()
//         rootItem = nil
//         lock.unlock()
//         reply(nil)
//     }
// }

// // MARK: - ReadWriteOperations Implementation

// extension OverlayVolume: FSVolume.ReadWriteOperations {
//     func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> Int {
//         guard let overlayItem = item as? OverlayItem else {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: nil)
//         }
        
//         let path = overlayItem.effectivePath
//         let fd = Darwin.open(path, O_RDONLY)
//         if fd == -1 {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//         }
//         defer { Darwin.close(fd) }
        
//         // Seek to the offset
//         if Darwin.lseek(fd, offset, SEEK_SET) == -1 {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//         }
        
//         // Read the data
//         var bytesRead = 0
//         var tempBuffer = [UInt8](repeating: 0, count: length)
        
//         bytesRead = Darwin.read(fd, &tempBuffer, length)
//         if bytesRead == -1 {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//         }
        
//         if bytesRead > 0 {
//             // Copy to the provided buffer
//             let data = Data(bytes: tempBuffer, count: bytesRead)
//             buffer.replaceBytes(in: 0..<bytesRead, with: data)
//         }
        
//         return bytesRead
//     }
    
//     func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler reply: @escaping (Int, (Error)?) -> Void) {
//         Task {
//             do {
//                 let bytesRead = try await read(from: item, at: offset, length: length, into: buffer)
//                 reply(bytesRead, nil)
//             } catch {
//                 reply(0, error)
//             }
//         }
//     }
    
//     func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
//         guard let overlayItem = item as? OverlayItem else {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: nil)
//         }
        
//         // If file exists only in lower layer, we need to copy it up first
//         if !overlayItem.existsInUpper {
//             try copyUp(item: overlayItem)
//         }
        
//         guard let upperPath = overlayItem.upperPath else {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: nil)
//         }
        
//         let fd = Darwin.open(upperPath, O_WRONLY)
//         if fd == -1 {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//         }
//         defer { Darwin.close(fd) }
        
//         // Seek to the offset
//         if Darwin.lseek(fd, offset, SEEK_SET) == -1 {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//         }
        
//         // Write the data
//         var bytesWritten = 0
//         contents.withUnsafeBytes { pointer in
//             bytesWritten = Darwin.write(fd, pointer.baseAddress, contents.count)
//         }
        
//         if bytesWritten == -1 {
//             throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
//         }
        
//         return bytesWritten
//     }
    
//     func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping (Int, (Error)?) -> Void) {
//         Task {
//             do {
//                 let bytesWritten = try await write(contents: contents, to: item, at: offset)
//                 reply(bytesWritten, nil)
//             } catch {
//                 reply(0, error)
//             }
//         }
//     }
// }

