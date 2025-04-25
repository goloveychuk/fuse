// import Foundation
// import FSKit
// import Darwin // For syscalls and POSIX constants

// // MARK: - Error Handling Helper

// func fs_errorForPOSIXError(_ posixError: Int32) -> Error {
//     return NSError(domain: NSPOSIXErrorDomain, code: Int(posixError), userInfo: nil)
// }

// // MARK: - Attribute Helpers

// // Helper function to convert stat structure to FSItem.Attributes
// private func attributesFromStat(_ statInfo: stat, fileId: FSItem.Identifier, parentId: FSItem.Identifier, itemType: FSItem.ItemType) -> FSItem.Attributes {
//     let attributes = FSItem.Attributes()
//     attributes.fileID = fileId
//     attributes.parentID = parentId
//     attributes.ownerID = statInfo.st_uid
//     attributes.groupID = statInfo.st_gid
//     attributes.size = UInt64(statInfo.st_size)
//     attributes.allocSize = UInt64(statInfo.st_blocks * 512) // st_blocks is in 512-byte units
//     attributes.linkCount = UInt32(statInfo.st_nlink)
//     attributes.permissions = UInt16(statInfo.st_mode & 0o7777) // Permissions mask
//     attributes.type = itemType
//     attributes.mode = statInfo.st_mode // Full mode including type

//     // Convert timespec to Date
//     attributes.accessTime = Date(timeIntervalSince1970: TimeInterval(statInfo.st_atimespec.tv_sec) + TimeInterval(statInfo.st_atimespec.tv_nsec) / 1_000_000_000)
//     attributes.modifyTime = Date(timeIntervalSince1970: TimeInterval(statInfo.st_mtimespec.tv_sec) + TimeInterval(statInfo.st_mtimespec.tv_nsec) / 1_000_000_000)
//     attributes.changeTime = Date(timeIntervalSince1970: TimeInterval(statInfo.st_ctimespec.tv_sec) + TimeInterval(statInfo.st_ctimespec.tv_nsec) / 1_000_000_000)
//     attributes.birthTime = Date(timeIntervalSince1970: TimeInterval(statInfo.st_birthtimespec.tv_sec) + TimeInterval(statInfo.st_birthtimespec.tv_nsec) / 1_000_000_000)
//     // attributes.backupTime = nil // Not directly available in stat
//     // attributes.addedTime = nil // Not directly available in stat

//     return attributes
// }

// // Helper function to convert SetAttributesRequest times to timespec for futimens/utimensat
// private func timespecFromSetAttributes(_ request: FSItem.SetAttributesRequest) -> (access: timespec?, modify: timespec?) {
//     var atime: timespec? = nil
//     var mtime: timespec? = nil

//     if request.isValid(.accessTime), let date = request.accessTime {
//         let timeInterval = date.timeIntervalSince1970
//         atime = timespec(tv_sec: Int(timeInterval), tv_nsec: Int((timeInterval - TimeInterval(Int(timeInterval))) * 1_000_000_000))
//     }
//     if request.isValid(.modifyTime), let date = request.modifyTime {
//         let timeInterval = date.timeIntervalSince1970
//         mtime = timespec(tv_sec: Int(timeInterval), tv_nsec: Int((timeInterval - TimeInterval(Int(timeInterval))) * 1_000_000_000))
//     }
    
//     return (atime, mtime)
// }


// // MARK: - PortalDirFSItem

// final class PortalDirFSItem: FSItem, WriteFSItemProtocol {
//     let fileId: FSItem.Identifier
//     let parentId: FSItem.Identifier
//     let filename: FSFileName // Name of this directory relative to its parent (or volume name for root)
//     private let dirFD: Int32 // File descriptor for the directory itself
//     let itemType: FSItem.ItemType = .directory

//     // Note: Takes ownership of the provided fd if dupFD is false.
//     // It's generally safer to pass dupFD = true unless the caller explicitly manages the original FD.
//     init(dirFD: Int32, fileId: FSItem.Identifier, parentId: FSItem.Identifier, filename: FSFileName, dupFD: Bool = true) throws {
//         self.fileId = fileId
//         self.parentId = parentId
//         self.filename = filename

//         if dupFD {
//             let newFD = Darwin.dup(dirFD)
//             if newFD == -1 {
//                 throw fs_errorForPOSIXError(errno)
//             }
//             self.dirFD = newFD
//         } else {
//             self.dirFD = dirFD
//         }
//         super.init()
//     }

//     deinit {
//         // Close the duplicated file descriptor when the object is deallocated
//         Darwin.close(dirFD)
//     }

//     // MARK: - FSItemProtocol

//     func getChildren() throws -> [(FSFileName, FSItemProtocol)] {
//         // Use fdopendir to get a DIR* stream from the file descriptor
//         guard let dirStream = fdopendir(dirFD) else {
//             // fdopendir consumes the fd on success, but not on failure.
//             // Since we might have duped the FD, we need to be careful here.
//             // If we didn't dup, the original FD is now invalid if fdopendir succeeded.
//             // If we did dup, the original FD is fine, but the dup'ed one (self.dirFD) might be consumed.
//             // Let's re-dup self.dirFD before calling fdopendir to be safe.
//             let tempFD = Darwin.dup(self.dirFD)
//             if tempFD == -1 { throw fs_errorForPOSIXError(errno) }
//             guard let dirStream = fdopendir(tempFD) else {
//                  Darwin.close(tempFD) // Close the temp FD if fdopendir failed
//                  throw fs_errorForPOSIXError(errno)
//             }
//             // If fdopendir succeeded, tempFD is now managed by dirStream.
//             defer { closedir(dirStream) } // Ensure stream is closed

//             var children: [(FSFileName, FSItemProtocol)] = []
//             let baseId = self.fileId // Use current dir ID as base for children

//             while let entry = readdir(dirStream) {
//                 var entryRef = entry.pointee
//                 let name = withUnsafeBytes(of: &entryRef.d_name) { rawPtr -> String? in
//                     let ptr = rawPtr.baseAddress!.assumingMemoryBound(to: CChar.self)
//                     // Ensure null termination within the fixed-size buffer
//                     if memchr(ptr, 0, Int(entryRef.d_namlen)) == nil { return nil } // Should not happen with readdir
//                     return String(cString: ptr)
//                 }

//                 guard let nameStr = name, nameStr != "." && nameStr != ".." else {
//                     continue // Skip . and ..
//                 }

//                 let childFileName = FSFileName(string: nameStr)

//                 // Use fstatat to get info about the child without opening it yet
//                 var statInfo = stat()
//                 let statResult = nameStr.withCString { namePtr in
//                     fstatat(self.dirFD, namePtr, &statInfo, AT_SYMLINK_NOFOLLOW)
//                 }

//                 if statResult == -1 {
//                     print("Warning: fstatat failed for \(nameStr): \(String(cString: strerror(errno)))")
//                     continue // Skip this child if stat fails
//                 }

//                 // Simple child ID generation (replace with a robust mechanism)
//                 let childId = baseId.advance(by: Int(statInfo.st_ino)) // Using inode as offset for simplicity

//                 let childItem: FSItemProtocol
//                 let modeType = statInfo.st_mode & S_IFMT

//                 if modeType == S_IFDIR {
//                     // Open the child directory to get its FD
//                     let childDirFD = nameStr.withCString { namePtr in
//                         openat(self.dirFD, namePtr, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
//                     }
//                     if childDirFD == -1 {
//                         print("Warning: openat failed for directory \(nameStr): \(String(cString: strerror(errno)))")
//                         continue // Skip this child
//                     }
//                     // Pass dupFD: false as we just opened it and want PortalDirFSItem to own it
//                     childItem = try PortalDirFSItem(dirFD: childDirFD, fileId: childId, parentId: self.fileId, filename: childFileName, dupFD: false)

//                 } else if modeType == S_IFLNK {
//                     // For symlinks, we don't need a specific FD, just parent info
//                     childItem = PortalFileFSItem(parentDirFD: self.dirFD, filename: childFileName, fileId: childId, parentId: self.fileId, itemType: .symlink)

//                 } else if modeType == S_IFREG {
//                     // For regular files, we don't need a specific FD, just parent info
//                     childItem = PortalFileFSItem(parentDirFD: self.dirFD, filename: childFileName, fileId: childId, parentId: self.fileId, itemType: .file)
//                 } else {
//                     // Skip other types for now (sockets, pipes, etc.)
//                     print("Warning: Skipping unsupported file type \(modeType) for \(nameStr)")
//                     continue
//                 }
//                 children.append((childFileName, childItem))
//             }
//             // Check errno after loop in case readdir failed
//             if errno != 0 && children.isEmpty { // Check if readdir itself failed mid-iteration
//                 throw fs_errorForPOSIXError(errno)
//             }

//             return children
//         }
//         // This part is only reached if the initial fdopendir fails
//         throw fs_errorForPOSIXError(errno)
//     }


//     func getChild(name: FSFileName) throws -> FSItemProtocol? {
//         guard let nameStr = name.string else {
//             throw fs_errorForPOSIXError(EINVAL)
//         }

//         var statInfo = stat()
//         let result = nameStr.withCString { namePtr in
//             fstatat(dirFD, namePtr, &statInfo, AT_SYMLINK_NOFOLLOW)
//         }

//         if result == -1 {
//             if errno == ENOENT {
//                 return nil // Not found
//             }
//             throw fs_errorForPOSIXError(errno)
//         }

//         // Simple child ID generation (replace with a robust mechanism)
//         let childId = self.fileId.advance(by: Int(statInfo.st_ino)) // Using inode as offset

//         let modeType = statInfo.st_mode & S_IFMT
//         if modeType == S_IFDIR {
//             let childDirFD = nameStr.withCString { namePtr in
//                 openat(dirFD, namePtr, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
//             }
//             if childDirFD == -1 {
//                 throw fs_errorForPOSIXError(errno)
//             }
//             // Pass dupFD: false as we just opened it
//             return try PortalDirFSItem(dirFD: childDirFD, fileId: childId, parentId: self.fileId, filename: name, dupFD: false)
//         } else if modeType == S_IFLNK {
//             return PortalFileFSItem(parentDirFD: dirFD, filename: name, fileId: childId, parentId: self.fileId, itemType: .symlink)
//         } else if modeType == S_IFREG {
//             return PortalFileFSItem(parentDirFD: dirFD, filename: name, fileId: childId, parentId: self.fileId, itemType: .file)
//         } else {
//             // Unsupported type found
//             throw fs_errorForPOSIXError(ENOTSUP)
//         }
//     }

//     func getAttributes() throws -> FSItem.Attributes {
//         var statInfo = stat()
//         if fstat(dirFD, &statInfo) == -1 {
//             throw fs_errorForPOSIXError(errno)
//         }
//         return attributesFromStat(statInfo, fileId: self.fileId, parentId: self.parentId, itemType: .directory)
//     }

//     func readSymbolicLink() throws -> FSFileName {
//         throw fs_errorForPOSIXError(EINVAL) // Cannot read symlink of a directory
//     }

//     func readData(offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) throws -> Int {
//         throw fs_errorForPOSIXError(EISDIR) // Cannot read data from a directory
//     }

//     // MARK: - WriteFSItemProtocol

//     func setAttributes(newAttributes: FSItem.SetAttributesRequest) throws -> FSItem.Attributes {
//         // 1. Change owner/group (fchown)
//         if newAttributes.isValid(.uid) || newAttributes.isValid(.gid) {
//             let uid = newAttributes.isValid(.uid) ? newAttributes.uid : uid_t(-1) // -1 means don't change
//             let gid = newAttributes.isValid(.gid) ? newAttributes.gid : gid_t(-1) // -1 means don't change
//             if fchown(dirFD, uid, gid) == -1 {
//                 throw fs_errorForPOSIXError(errno)
//             }
//         }

//         // 2. Change permissions (fchmod)
//         if newAttributes.isValid(.mode) {
//              // We only care about the permission bits, not the file type bits from mode
//             let mode = mode_t(newAttributes.mode & 0o7777)
//             if fchmod(dirFD, mode) == -1 {
//                 throw fs_errorForPOSIXError(errno)
//             }
//         }

//         // 3. Change times (futimens)
//         let (atimeSpec, mtimeSpec) = timespecFromSetAttributes(newAttributes)
//         if atimeSpec != nil || mtimeSpec != nil {
//             // futimens requires an array of two timespecs: [atime, mtime]
//             // Use UTIME_OMIT if one is nil.
//             var times = [atimeSpec ?? timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
//                          mtimeSpec ?? timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))]
//             if futimens(dirFD, &times) == -1 {
//                 // EINVAL might mean UTIME_OMIT is needed if one was nil
//                 throw fs_errorForPOSIXError(errno)
//             }
//         }

//         // 4. Change BSD Flags (fchflags) - Optional
//         // if newAttributes.isValid(.bsdFlags) {
//         //     if fchflags(dirFD, newAttributes.bsdFlags) == -1 {
//         //         throw fs_errorForPOSIXError(errno)
//         //     }
//         // }

//         // Size cannot be set on a directory, ignore if requested.

//         // Return updated attributes
//         return try getAttributes()
//     }

//     func writeData(contents: Data, offset: off_t) throws -> Int {
//         throw fs_errorForPOSIXError(EISDIR) // Cannot write data to a directory
//     }

//     func removeItem(name: FSFileName, fromDirectory: FSItem) throws {
//         guard let nameStr = name.string else {
//             throw fs_errorForPOSIXError(EINVAL)
//         }
        
//         // First determine if it's a directory or not using fstatat
//         var statInfo = stat()
//         let statResult = nameStr.withCString { namePtr in
//             fstatat(dirFD, namePtr, &statInfo, AT_SYMLINK_NOFOLLOW)
//         }
        
//         if statResult == -1 {
//             if errno == ENOENT {
//                 return // Already gone, nothing to do (POSIX compliant)
//             }
//             throw fs_errorForPOSIXError(errno)
//         }
        
//         let isDirectory = (statInfo.st_mode & S_IFMT) == S_IFDIR
//         let flags = isDirectory ? AT_REMOVEDIR : 0
        
//         // Use unlinkat to remove the file or directory
//         let unlinkResult = nameStr.withCString { namePtr in
//             unlinkat(dirFD, namePtr, flags)
//         }
        
//         if unlinkResult == -1 {
//             // Common errors: EPERM (permissions), ENOTEMPTY (dir not empty)
//             throw fs_errorForPOSIXError(errno)
//         }
//     }

//     func createLink(to name: FSFileName, inDirectory destinationDirectory: FSItem) throws -> FSFileName {
//          // Hard links are complex with FDs. We need the *target* path relative to its dirFD,
//          // and the *new link* path relative to the destination dirFD.
//          // This implementation assumes destinationDirectory is the *same* as this directory item.
//          // Linking across different directory items represented by PortalDirFSItem needs more info.
//         guard let destinationDir = destinationDirectory as? PortalDirFSItem, destinationDir.dirFD == self.dirFD else {
//              throw fs_errorForPOSIXError(EXDEV) // Cross-device link (or simplified error for different dir items)
//         }
//         guard let targetItemPath = (self as? FSItemProtocol)?.filename.string else { // Assuming self represents the target file/dir *within* a parent not represented here. This is confusing.
//              // Let's rethink: createLink is called on the *target* item.
//              // 'name' is the new link name. 'destinationDirectory' is where to put it.
//              // We need the path of the *target* relative to the *destinationDirectory*'s FD.
//              // This structure makes hard links difficult without absolute paths or a common root FD.
//              // For now, let's assume the target is also in the destinationDirectory.
//              throw fs_errorForPOSIXError(ENOSYS) // Hard links not fully supported in this structure yet.

//              /* // Hypothetical implementation if target path was known relative to destinationDir.dirFD
//              guard let targetPathStr = targetItem.filename.string, // Need the target item's name
//                    let newLinkNameStr = name.string else {
//                  throw fs_errorForPOSIXError(EINVAL)
//              }

//              let result = targetPathStr.withCString { targetPtr in
//                  newLinkNameStr.withCString { linkPtr in
//                      linkat(destinationDir.dirFD, targetPtr, destinationDir.dirFD, linkPtr, 0) // AT_SYMLINK_FOLLOW = 0
//                  }
//              }

//              if result == -1 {
//                  throw fs_errorForPOSIXError(errno)
//              }
//              return name // Return the new link name
//              */
//     }


//     func renameItem(inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?) throws -> FSFileName {
//         guard let sourceDir = sourceDirectory as? PortalDirFSItem,
//               let destDir = destinationDirectory as? PortalDirFSItem else {
//             throw fs_errorForPOSIXError(EINVAL) // Must be PortalDirFSItems
//         }
//         guard let sourceNameStr = sourceName.string,
//               let destNameStr = destinationName.string else {
//             throw fs_errorForPOSIXError(EINVAL)
//         }

//         // Use renameat to perform the rename atomically
//         let result = sourceNameStr.withCString { srcPtr in
//             destNameStr.withCString { dstPtr in
//                 renameat(sourceDir.dirFD, srcPtr, destDir.dirFD, dstPtr)
//             }
//         }

//         if result == -1 {
//             // Common errors: EPERM, ENOENT, EEXIST (if dest exists and isn't replaceable), EXDEV (cross-device)
//             throw fs_errorForPOSIXError(errno)
//         }

//         return destinationName // Return the new name
//     }

//     func createSymbolicLink(named name: FSFileName, attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName) throws -> (FSItem, FSFileName) {
//         guard let nameStr = name.string,
//               let contentsStr = contents.string else {
//             throw fs_errorForPOSIXError(EINVAL)
//         }

//         // Use symlinkat to create the symbolic link
//         let result = contentsStr.withCString { targetPtr in
//             nameStr.withCString { linkPtr in
//                 symlinkat(targetPtr, dirFD, linkPtr)
//             }
//         }

//         if result == -1 {
//             throw fs_errorForPOSIXError(errno)
//         }

//         // Get the newly created item
//         guard let newItem = try getChild(name: name) else {
//             // Should exist now, if not, something went wrong post-creation
//             throw fs_errorForPOSIXError(EIO)
//         }

//         // Apply attributes (optional, symlinkat doesn't take mode directly)
//         // For symlinks we'd need fchownat(AT_SYMLINK_NOFOLLOW), etc.
//         if newAttributes.isValid(.uid) || newAttributes.isValid(.gid) {
//             let uid = newAttributes.isValid(.uid) ? newAttributes.uid : uid_t(-1)
//             let gid = newAttributes.isValid(.gid) ? newAttributes.gid : gid_t(-1)
//             let attrResult = nameStr.withCString { namePtr in
//                 fchownat(dirFD, namePtr, uid, gid, AT_SYMLINK_NOFOLLOW)
//             }
//             if attrResult == -1 {
//                 // Log error but don't fail the operation
//                 print("Warning: Failed to set ownership on symlink \(nameStr): \(String(cString: strerror(errno)))")
//             }
//         }
//          // Setting times on symlinks requires utimensat with AT_SYMLINK_NOFOLLOW
//          let (atimeSpec, mtimeSpec) = timespecFromSetAttributes(newAttributes)
//          if atimeSpec != nil || mtimeSpec != nil {
//              var times = [atimeSpec ?? timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
//                           mtimeSpec ?? timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))]
//              let timeResult = nameStr.withCString { namePtr in
//                  utimensat(dirFD, namePtr, &times, AT_SYMLINK_NOFOLLOW)
//              }
//              if timeResult == -1 {
//                  print("Warning: Failed to set times on symlink \(nameStr): \(String(cString: strerror(errno)))")
//              }
//          }
//          // Mode on symlinks isn't really used, skip fchmodat

//         return (newItem, name)
//     }

//     func createItem(named name: FSFileName, type: FSItem.ItemType, attributes newAttributes: FSItem.SetAttributesRequest) throws -> (FSItem, FSFileName) {
//         guard let nameStr = name.string else {
//             throw fs_errorForPOSIXError(EINVAL)
//         }

//         // Extract mode from attributes, default if not provided
//         let mode = mode_t(newAttributes.isValid(.mode) ? (newAttributes.mode & 0o777) : (type == .directory ? 0o755 : 0o644)) // Apply only permission bits

//         let newItem: FSItemProtocol
//         if type == .directory {
//             // Use mkdirat to create a directory
//             let result = nameStr.withCString { namePtr in
//                 mkdirat(dirFD, namePtr, mode)
//             }
//             if result == -1 {
//                 throw fs_errorForPOSIXError(errno)
//             }
//             // Get the newly created item
//             guard let createdItem = try getChild(name: name) else { 
//                 throw fs_errorForPOSIXError(EIO) // Should exist now
//             }
//             newItem = createdItem

//         } else if type == .file {
//             // Use openat with O_CREAT | O_EXCL to ensure atomicity and avoid overwriting
//             let fileFD = nameStr.withCString { namePtr in
//                 // O_RDWR allows subsequent writes/reads if needed, O_CLOEXEC is good practice
//                 openat(dirFD, namePtr, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode)
//             }
//             if fileFD == -1 {
//                 throw fs_errorForPOSIXError(errno)
//             }
//             // Close immediately, we just needed to create it using the relative path.
//             // The PortalFileFSItem will use openat again when needed.
//             Darwin.close(fileFD)

//             // Get the newly created item
//             guard let createdItem = try getChild(name: name) else { 
//                 throw fs_errorForPOSIXError(EIO) // Should exist now
//             }
//             newItem = createdItem
//         } else {
//             throw fs_errorForPOSIXError(ENOTSUP) // Type not supported for creation (e.g., symlink needs createSymbolicLink)
//         }

//         // Apply other attributes (owner, group, times) if specified
//         // We need to apply them to the newly created item using fchownat/utimensat relative to dirFD
//         if newAttributes.isValid(.uid) || newAttributes.isValid(.gid) {
//             let uid = newAttributes.isValid(.uid) ? newAttributes.uid : uid_t(-1)
//             let gid = newAttributes.isValid(.gid) ? newAttributes.gid : gid_t(-1)
//             let ownerResult = nameStr.withCString { namePtr in
//                 fchownat(dirFD, namePtr, uid, gid, AT_SYMLINK_NOFOLLOW) // Use NOFOLLOW just in case (though shouldn't be symlink here)
//             }
//             if ownerResult == -1 {
//                  print("Warning: Failed to set ownership on \(nameStr): \(String(cString: strerror(errno)))")
//                  // Don't throw, creation succeeded
//             }
//         }

//         let (atimeSpec, mtimeSpec) = timespecFromSetAttributes(newAttributes)
//         if atimeSpec != nil || mtimeSpec != nil {
//             var times = [atimeSpec ?? timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
//                          mtimeSpec ?? timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))]
//             let timeResult = nameStr.withCString { namePtr in
//                 utimensat(dirFD, namePtr, &times, 0) // Don't use NOFOLLOW for files/dirs
//             }
//              if timeResult == -1 {
//                  print("Warning: Failed to set times on \(nameStr): \(String(cString: strerror(errno)))")
//                  // Don't throw
//              }
//         }
        
//         // Note: Mode was already set during creation (mkdirat/openat)

//         return (newItem, name)
//     }
// }


// // MARK: - PortalFileFSItem
// final class PortalFileFSItem: FSItem, WriteFSItemProtocol {
//     let fileId: FSItem.Identifier
//     let parentId: FSItem.Identifier
//     let filename: FSFileName // Name relative to parentDirFD
//     let itemType: FSItem.ItemType // Can be .file or .symlink
//     private let parentDirFD: Int32 // FD of the parent directory (borrowed, not owned)

//     init(parentDirFD: Int32, filename: FSFileName, fileId: FSItem.Identifier, parentId: FSItem.Identifier, itemType: FSItem.ItemType) {
//         guard itemType == .file || itemType == .symlink else {
//             // Or handle other types if necessary
//             fatalError("PortalFileFSItem only supports .file and .symlink types")
//         }
//         self.parentDirFD = parentDirFD // Note: No dup, assumes parent PortalDirFSItem manages its FD lifetime
//         self.filename = filename
//         self.fileId = fileId
//         self.parentId = parentId
//         self.itemType = itemType
//         super.init()
//     }

//     // MARK: - FSItemProtocol

//     func getChildren() throws -> [(FSFileName, FSItemProtocol)] {
//         throw fs_errorForPOSIXError(ENOTDIR)
//     }

//     func getChild(name: FSFileName) throws -> FSItemProtocol? {
//         throw fs_errorForPOSIXError(ENOTDIR)
//     }

//     func getAttributes() throws -> FSItem.Attributes {
//         guard let nameStr = filename.string else {
//             throw fs_errorForPOSIXError(EINVAL)
//         }
//         var statInfo = stat()
//         // Use AT_SYMLINK_NOFOLLOW to get attributes of the link itself if it's a symlink
//         let result = nameStr.withCString { namePtr in
//             fstatat(parentDirFD, namePtr, &statInfo, AT_SYMLINK_NOFOLLOW)
//         }
//         if result == -1 {
//             throw fs_errorForPOSIXError(errno)
//         }
//         // Determine actual type from stat, might differ from init if symlink changed race condition?
//         let actualType: FSItem.ItemType
//         switch statInfo.st_mode & S_IFMT {
//             case S_IFREG: actualType = .file
//             case S_IFLNK: actualType = .symlink
//             // case S_IFDIR: actualType = .directory // Should not happen if called on PortalFileFSItem
//             default: actualType = .unknown // Or handle other types
//         }
//         // Use the actual type found, but the original fileId/parentId
//         return attributesFromStat(statInfo, fileId: self.fileId, parentId: self.parentId, itemType: actualType)
//     }

//      func readSymbolicLink() throws -> FSFileName {
//          guard itemType == .symlink else {
//              throw fs_errorForPOSIXError(EINVAL) // Not a symlink
//          }
//          guard let nameStr = filename.string else {
//              throw fs_errorForPOSIXError(EINVAL)
//          }

//          // Need to determine buffer size. PATH_MAX is a common upper bound.
//          let bufferSize = Int(PATH_MAX) + 1
//          var buffer = [CChar](repeating: 0, count: bufferSize)

//          let bytesRead = nameStr.withCString { namePtr in
//              // Use readlinkat relative to the parent directory FD
//              readlinkat(parentDirFD, namePtr, &buffer, bufferSize - 1) // Leave space for null terminator
//          }

//          if bytesRead == -1 {
//              throw fs_errorForPOSIXError(errno)
//          }

//          // Ensure null termination (readlinkat doesn't guarantee it)
//          buffer[bytesRead] = 0
//          let linkTarget = String(cString: buffer)
//          return FSFileName(string: linkTarget)
//      }

//      func readData(offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) throws -> Int {
//          guard itemType == .file else {
//              // Cannot read data from a symlink directly this way
//              throw fs_errorForPOSIXError(itemType == .symlink ? EPERM : EBADF)
//          }
//          guard let nameStr = filename.string else {
//              throw fs_errorForPOSIXError(EINVAL)
//          }

//          // Open the file relative to the parent directory FD for reading
//          let fileFD = nameStr.withCString { namePtr in
//              openat(parentDirFD, namePtr, O_RDONLY | O_CLOEXEC)
//          }
//          if fileFD == -1 {
//              throw fs_errorForPOSIXError(errno)
//          }
//          defer { Darwin.close(fileFD) }

//          // Use pread to read from the specified offset
//          let bytesRead = try buffer.withUnsafeMutableBytes { rawBufferPointer -> Int in
//              guard let baseAddress = rawBufferPointer.baseAddress else {
//                  // Handle case where buffer is empty or invalid
//                  return 0
//              }
//              // Ensure we don't read past the buffer's capacity
//              let readLength = min(length, rawBufferPointer.count)
//              if readLength <= 0 { return 0 }

//              let readResult = Darwin.pread(fileFD, baseAddress, readLength, offset)
//              if readResult == -1 {
//                  throw fs_errorForPOSIXError(errno)
//              }
//              return readResult
//          }
//          return bytesRead
//      }

//     // MARK: - WriteFSItemProtocol

//     func setAttributes(newAttributes: FSItem.SetAttributesRequest) throws -> FSItem.Attributes {
//         guard let nameStr = filename.string else {
//             throw fs_errorForPOSIXError(EINVAL)
//         }
        
//         // Use AT_SYMLINK_NOFOLLOW for operations that should affect the link itself
//         let noFollowFlag = (itemType == .symlink) ? AT_SYMLINK_NOFOLLOW : 0

//         // 1. Change owner/group (fchownat)
//         if newAttributes.isValid(.uid) || newAttributes.isValid(.gid) {
//             let uid = newAttributes.isValid(.uid) ? newAttributes.uid : uid_t(-1)
//             let gid = newAttributes.isValid(.gid) ? newAttributes.gid : gid_t(-1)
//             let result = nameStr.withCString { namePtr in
//                 fchownat(parentDirFD, namePtr, uid, gid, noFollowFlag)
//             }
//             if result == -1 {
//                 throw fs_errorForPOSIXError(errno)
//             }
//         }

//         // 2. Change permissions (fchmodat) - Only applies to files, not symlinks
//         if itemType == .file && newAttributes.isValid(.mode) {
//             let mode = mode_t(newAttributes.mode & 0o7777) // Mask out file type bits
//             let result = nameStr.withCString { namePtr in
//                 fchmodat(parentDirFD, namePtr, mode, 0) // No flags needed here
//             }
//              if result == -1 {
//                 throw fs_errorForPOSIXError(errno)
//             }
//         }

//         // 3. Change times (utimensat)
//         let (atimeSpec, mtimeSpec) = timespecFromSetAttributes(newAttributes)
//         if atimeSpec != nil || mtimeSpec != nil {
//             var times = [atimeSpec ?? timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
//                          mtimeSpec ?? timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))]
//             let result = nameStr.withCString { namePtr in
//                 utimensat(parentDirFD, namePtr, &times, noFollowFlag)
//             }
//              if result == -1 {
//                 throw fs_errorForPOSIXError(errno)
//             }
//         }

//         // 4. Change size (truncate) - Only for regular files
//         if itemType == .file && newAttributes.isValid(.size) {
//              let size = off_t(newAttributes.size)
//              // Need to open the file to truncate it relative to parent FD
//              let fileFD = nameStr.withCString { namePtr in
//                  openat(parentDirFD, namePtr, O_WRONLY | O_CLOEXEC)
//              }
//              if fileFD == -1 {
//                  throw fs_errorForPOSIXError(errno) // Error opening file
//              }
//              defer { Darwin.close(fileFD) }

//              if Darwin.ftruncate(fileFD, size) == -1 {
//                  throw fs_errorForPOSIXError(errno) // Error truncating
//              }
//         }

//         // BSD Flags not handled here (would need open + fchflags or fchflagsat)

//         return try getAttributes() // Return potentially updated attributes
//     }

//     func writeData(contents: Data, offset: off_t) throws -> Int {
//         guard itemType == .file else {
//             // Cannot write data to a symlink directly this way
//             throw fs_errorForPOSIXError(EPERM)
//         }
//          guard let nameStr = filename.string else {
//             throw fs_errorForPOSIXError(EINVAL)
//         }

//         // Open the file relative to the parent directory FD for writing
//         let fileFD = nameStr.withCString { namePtr in
//             // Use O_WRONLY. O_CREAT is not needed as the item should exist.
//             openat(parentDirFD, namePtr, O_WRONLY | O_CLOEXEC)
//         }
//         if fileFD == -1 {
//             throw fs_errorForPOSIXError(errno)
//         }
//         defer { Darwin.close(fileFD) }

//         // Use pwrite to write at the specified offset
//         let bytesWritten = contents.withUnsafeBytes { rawBufferPointer -> Int in
//             guard let baseAddress = rawBufferPointer.baseAddress else { return 0 }
//             let writeResult = Darwin.pwrite(fileFD, baseAddress, contents.count, offset)
//             return writeResult
//         }

//         if bytesWritten == -1 {
//             throw fs_errorForPOSIXError(errno)
//         }
//         return bytesWritten
//     }

//     // Operations below typically act on the parent directory, so they throw errors here.
//     // The actual operation is handled by the PortalDirFSItem containing this file/link.

//     func removeItem(name: FSFileName, fromDirectory: FSItem) throws {
//         throw fs_errorForPOSIXError(EPERM) // Operation should be called on the parent directory item
//     }

//     func createLink(to name: FSFileName, inDirectory destinationDirectory: FSItem) throws -> FSFileName {
//         throw fs_errorForPOSIXError(EPERM) // Operation should be called on the parent directory item
//     }

//     func renameItem(inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?) throws -> FSFileName {
//         throw fs_errorForPOSIXError(EPERM) // Operation should be called on the parent directory item
//     }

//     func createSymbolicLink(named name: FSFileName, attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName) throws -> (FSItem, FSFileName) {
//         throw fs_errorForPOSIXError(ENOTDIR) // Cannot create items inside a file/symlink
//     }

//     func createItem(named name: FSFileName, type: FSItem.ItemType, attributes newAttributes: FSItem.SetAttributesRequest) throws -> (FSItem, FSFileName) {
//         throw fs_errorForPOSIXError(ENOTDIR) // Cannot create items inside a file/symlink
//     }
// }
