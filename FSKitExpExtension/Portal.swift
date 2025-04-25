// import Darwin
// import FSKit
// import Foundation
// import System

// private func mergeAttributes(
//     _ existing: FSItem.Attributes, request: FSItem.SetAttributesRequest
// ) {
//     if request.isValid(FSItem.Attribute.uid) {
//         existing.uid = request.uid
//     }

//     if request.isValid(FSItem.Attribute.gid) {
//         existing.gid = request.gid
//     }

//     if request.isValid(FSItem.Attribute.type) {
//         existing.type = request.type
//     }

//     if request.isValid(FSItem.Attribute.mode) {
//         existing.mode = request.mode
//     }

//     if request.isValid(FSItem.Attribute.linkCount) {
//         existing.linkCount = request.linkCount
//     }

//     if request.isValid(FSItem.Attribute.flags) {
//         existing.flags = request.flags
//     }

//     if request.isValid(FSItem.Attribute.size) {
//         existing.size = request.size
//     }

//     if request.isValid(FSItem.Attribute.allocSize) {
//         existing.allocSize = request.allocSize
//     }

//     if request.isValid(FSItem.Attribute.fileID) {
//         existing.fileID = request.fileID
//     }

//     if request.isValid(FSItem.Attribute.parentID) {
//         existing.parentID = request.parentID
//     }

//     if request.isValid(FSItem.Attribute.accessTime) {
//         let timespec = timespec()
//         request.accessTime = timespec
//         existing.accessTime = timespec
//     }

//     if request.isValid(FSItem.Attribute.changeTime) {
//         let timespec = timespec()
//         request.changeTime = timespec
//         existing.changeTime = timespec
//     }

//     if request.isValid(FSItem.Attribute.modifyTime) {
//         let timespec = timespec()
//         request.modifyTime = timespec
//         existing.modifyTime = timespec
//     }

//     if request.isValid(FSItem.Attribute.addedTime) {
//         let timespec = timespec()
//         request.addedTime = timespec
//         existing.addedTime = timespec
//     }

//     if request.isValid(FSItem.Attribute.birthTime) {
//         let timespec = timespec()
//         request.birthTime = timespec
//         existing.birthTime = timespec
//     }

//     if request.isValid(FSItem.Attribute.backupTime) {
//         let timespec = timespec()
//         request.backupTime = timespec
//         existing.backupTime = timespec
//     }
// }

// // MARK: - File Descriptor Wrappers

// /// Safe wrapper for directory file descriptors
// struct DirFd {
//     let rawValue: Int32

//     init(_ fd: Int32) {

//         self.rawValue = fd
//     }
// }

// struct Location {
//     let path: String
//     func sub(_ path: String) -> Location {
//         return Location(path: self.path + "/" + path)
//     }
// }

// /// Safe wrapper for regular file descriptors
// struct FileFd {
//     let rawValue: Int32

//     init(_ fd: Int32) {
//         self.rawValue = fd
//     }
// }

// // MARK: - Safe System Call Wrappers

// /// Namespace for safe system calls that validate return values and throw errors
// enum Safe {
//     static func openat(dirfd: DirFd, path: Location, flags: Int32, mode: mode_t = 0) throws -> FileFd
//     {
//         let fd = Darwin.openat(dirfd.rawValue, path, flags, mode)
//         guard fd >= 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//         return FileFd(fd)
//     }

//     static func openatDirectory(dirfd: DirFd, path: Location, flags: Int32, mode: mode_t = 0) throws
//         -> DirFd
//     {
//         let fd = Darwin.openat(dirfd.rawValue, path, flags | O_DIRECTORY, mode)
//         guard fd >= 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//         return DirFd(fd)
//     }

//     static func dup(fd: DirFd) throws -> DirFd {
//         let newFd = Darwin.dup(fd.rawValue)
//         guard newFd >= 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//         return DirFd(newFd)
//     }

//     static func fdopendir(fd: DirFd) throws -> UnsafeMutablePointer<DIR> {
//         // Duplicate the FD to avoid closing the original when fdopendir takes ownership
//         let tempFD = try Safe.dup(fd: DirFd(fd.rawValue))

//         guard let dir = Darwin.fdopendir(tempFD.rawValue) else {
//             try Safe.closeFD(dir: tempFD)
//             throw fs_errorForPOSIXError(errno)
//         }
//         return dir
//     }

//     static func closedir(dir: UnsafeMutablePointer<DIR>) throws {
//         guard Darwin.closedir(dir) == 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }

//     static func rewinddir(dir: UnsafeMutablePointer<DIR>) {
//         Darwin.rewinddir(dir)
//     }

//     static func closeFD(dir: DirFd) throws {
//         guard Darwin.close(dir.rawValue) == 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }
//     static func closeFD(file: FileFd) throws {
//         guard Darwin.close(file.rawValue) == 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }

//     static func readdir(dir: UnsafeMutablePointer<DIR>) throws -> UnsafeMutablePointer<dirent>? {
//         errno = 0
//         let entry = Darwin.readdir(dir)
//         if entry == nil && errno != 0 {
//             throw fs_errorForPOSIXError(errno)
//         }
//         return entry
//     }

//     static func fstatat(dirfd: DirFd, path: Location, statBuf: inout stat, flags: Int32 = 0) throws {
//         guard Darwin.fstatat(dirfd.rawValue, path, &statBuf, flags) == 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }

//     static func fstat(fd: FileFd, statBuf: inout stat) throws {
//         guard Darwin.fstat(fd.rawValue, &statBuf) == 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }

//     static func fstat(fd: DirFd, statBuf: inout stat) throws {
//         guard Darwin.fstat(fd.rawValue, &statBuf) == 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }

//     static func lseek(fd: FileFd, offset: off_t, whence: Int32) throws -> off_t {
//         let position = Darwin.lseek(fd.rawValue, offset, whence)
//         guard position >= 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//         return position
//     }

//     static func read(fd: FileFd, buffer: UnsafeMutableRawPointer, size: Int) throws -> Int {
//         let result = Darwin.read(fd.rawValue, buffer, size)
//         guard result >= 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//         return result
//     }

//     static func write(fd: FileFd, buffer: UnsafeRawPointer, size: Int) throws -> Int {
//         let result = Darwin.write(fd.rawValue, buffer, size)
//         guard result >= 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//         return result
//     }

//     static func fchmod(fd: FileFd, mode: mode_t) throws {
//         guard Darwin.fchmod(fd.rawValue, mode) == 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }

//     static func fchmod(fd: DirFd, mode: mode_t) throws {
//         guard Darwin.fchmod(fd.rawValue, mode) == 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }

//     static func fchown(fd: FileFd, uid: uid_t, gid: gid_t) throws {
//         guard Darwin.fchown(fd.rawValue, uid, gid) == 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }

//     static func fchown(fd: DirFd, uid: uid_t, gid: gid_t) throws {
//         guard Darwin.fchown(fd.rawValue, uid, gid) == 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }

//     static func futimens(fd: FileFd, times: [timespec]) throws {
//         guard times.count == 2 else {
//             throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
//         }
//         guard Darwin.futimens(fd.rawValue, times) == 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }

//     static func futimens(fd: DirFd, times: [timespec]) throws {
//         guard times.count == 2 else {
//             throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
//         }
//         guard Darwin.futimens(fd.rawValue, times) == 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }

//     static func ftruncate(fd: FileFd, size: off_t) throws {
//         guard Darwin.ftruncate(fd.rawValue, size) == 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }

//     static func unlinkat(dirfd: DirFd, path: String, flags: Int32 = 0) throws {
//         guard Darwin.unlinkat(dirfd.rawValue, path, flags) == 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }

//     static func mkdirat(dirfd: DirFd, path: Location, mode: mode_t) throws {
//         guard Darwin.mkdirat(dirfd.rawValue, path, mode) == 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }

//     static func readlinkat(dirfd: DirFd, path: Location, buffer: inout [CChar], size: Int) throws
//         -> Int
//     {
//         let result = Darwin.readlinkat(dirfd.rawValue, path, &buffer, size)
//         guard result >= 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//         return result
//     }

//     static func linkat(
//         fromDirfd: DirFd, fromPath: Location, toDirfd: DirFd, toPath: String, flags: Int32 = 0
//     ) throws {
//         guard Darwin.linkat(fromDirfd.rawValue, fromPath, toDirfd.rawValue, toPath, flags) == 0
//         else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }

//     static func symlinkat(target: String, dirfd: DirFd, path: String) throws {
//         guard Darwin.symlinkat(target, dirfd.rawValue, path) == 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }

//     static func fchownat(dirfd: DirFd, path: String, uid: uid_t, gid: gid_t, flags: Int32 = 0)
//         throws
//     {
//         guard Darwin.fchownat(dirfd.rawValue, path, uid, gid, flags) == 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }

//     static func renameat(fromDirfd: DirFd, fromPath: String, toDirfd: DirFd, toPath: String) throws
//     {
//         guard Darwin.renameat(fromDirfd.rawValue, fromPath, toDirfd.rawValue, toPath) == 0 else {
//             throw fs_errorForPOSIXError(errno)
//         }
//     }
// }

// /// PortalDirFSItem implements a directory that performs operations relative to a directory file descriptor
// final class PortalDirFSItem: FSItem, FSItemProtocol, WriteFSItemProtocol {
//     let fileId: FSItem.Identifier
//     let itemType: FSItem.ItemType = .directory
//     let parentId: FSItem.Identifier
//     private let dirFD: DirFd
//     private var cachedEntries: [String: FSItemProtocol]?
//     private let logger = Logger(subsystem: "FSKitExp", category: "PortalDir")
//     private let path: Location

//     init(fileId: FSItem.Identifier, parentId: FSItem.Identifier, dirFD: DirFd, path: Location) {
//         self.fileId = fileId
//         self.parentId = parentId
//         self.dirFD = dirFD
//         self.path = path
//         super.init()
//     }

//     let lock = NSLock()

//     func getChildren() throws -> [(FSFileName, FSItemProtocol)] {
//         if let entries = cachedEntries {
//             return entries.map { (FSFileName(string: $0.key), $0.value) }
//         }
//         lock.lock()
//         defer { lock.unlock() }

//         // Duplicate the directory FD only for listing
//         // let tempFD = try Safe.dup(fd: dirFD)
//         let dir = try Safe.fdopendir(fd: dirFD) //todo open
//         defer { try? Safe.closedir(dir: dir) }
        
//         Safe.rewinddir(dir: dir)

//         var entries = [String: FSItemProtocol]()
//         var nextID = fileId.advance(by: 1)

//         while let entry = try Safe.readdir(dir: dir) {
//             // Get entry name
//             let name = withUnsafePointer(to: entry.pointee.d_name) { ptr in
//                 String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
//             }

//             // Skip . and ..
//             if name == "." || name == ".." {
//                 continue
//             }

//             let type: FSItem.ItemType

//             // Determine type from d_type if available
//             switch entry.pointee.d_type {
//             case UInt8(DT_DIR):
//                 type = .directory
//             case UInt8(DT_REG):
//                 type = .file
//             case UInt8(DT_LNK):
//                 type = .symlink
//             default:
//                 // If d_type is unknown, use fstatat to determine
//                 var statBuf = stat()
//                 let entryPath = name
//                 do {
//                     try Safe.fstatat(
//                         dirfd: dirFD, path: entryPath, statBuf: &statBuf, flags: AT_SYMLINK_NOFOLLOW
//                     )
//                     if (statBuf.st_mode & S_IFMT) == S_IFDIR {
//                         type = .directory
//                     } else if (statBuf.st_mode & S_IFMT) == S_IFREG {
//                         type = .file
//                     } else if (statBuf.st_mode & S_IFMT) == S_IFLNK {
//                         type = .symlink
//                     } else {
//                         continue  // Skip unknown types
//                     }
//                 } catch {
//                     continue  // Skip if stat fails
//                 }
//             }
            
//             let subPath = path + "/" + name

//             if type == .directory {
//                 // Create directory item without opening an FD yet
//                 entries[name] = PortalDirFSItem(
//                     fileId: nextID, parentId: fileId, dirFD: dirFD, path: subPath)
//             } else {
//                 // Create file item without opening an FD yet
//                 entries[name] = PortalFileFSItem(
//                     fileId: nextID, parentId: fileId, dirFd: dirFD, fileFd: nil, path: name,
//                     itemType: type)
//             }

//             nextID = nextID.advance(by: 1)
//         }

//         // cachedEntries = entries
//         return entries.map { (FSFileName(string: $0.key), $0.value) }
//     }

//     func getChild(name: FSFileName) throws -> FSItemProtocol? {
//         guard let nameStr = name.string else {
//             return nil
//         }
//         lock.lock()
//         defer { lock.unlock() }

//         // Try getting from cache first
//         if let entries = cachedEntries, let item = entries[nameStr] {
//             return item
//         }

//         // Otherwise, open the file to check if it exists and determine its type
//         var statBuf = stat()

//         let subPath = location.sub(path: nameStr)


//         try Safe.fstatat(dirfd: dirFD, path: subPath, statBuf: &statBuf, flags: AT_SYMLINK_NOFOLLOW)

//         let nextID = fileId.advance(by: UInt64(nameStr.hash & 0x7FFF_FFFF))

//         let type: FSItem.ItemType
//         if (statBuf.st_mode & S_IFMT) == S_IFDIR {
//             type = .directory
//             do {
//                 let newFD = try Safe.openatDirectory(
//                     dirfd: dirFD, path: subPath, flags: O_RDONLY, mode: 0)
//                 return PortalDirFSItem(
//                     fileId: nextID, parentId: fileId, dirFD: newFD, path: subPath)
//             } catch {
//                 logger.error("Failed to open directory: \(error.localizedDescription)")
//                 return nil
//             }
//         } else if (statBuf.st_mode & S_IFMT) == S_IFREG {
//             type = .file

//             return PortalFileFSItem(
//                 fileId: nextID, parentId: fileId, dirFd: dirFD, fileFd: nil, path: subPath,
//                 itemType: type)

//         } else if (statBuf.st_mode & S_IFMT) == S_IFLNK {
//             type = .symlink

//             return PortalFileFSItem(
//                 fileId: nextID, parentId: fileId, dirFd: dirFD, fileFd: nil, path: subPath,
//                 itemType: type)
//         }

//         return nil
//     }

//     func getAttributes() throws -> FSItem.Attributes {
//         var statBuf = stat()
//         try Safe.fstat(fd: dirFD, statBuf: &statBuf)

//         let attributes = FSItem.Attributes()
//         attributes.fileID = fileId
//         attributes.parentID = parentId
//         attributes.type = .directory
//         attributes.uid = statBuf.st_uid
//         attributes.gid = statBuf.st_gid
//         attributes.mode = UInt32(statBuf.st_mode & 0o777) | UInt32(S_IFDIR)
//         attributes.linkCount = UInt32(statBuf.st_nlink)
//         attributes.size = UInt64(statBuf.st_size)
//         attributes.allocSize = UInt64(statBuf.st_blocks * 512)

//         attributes.birthTime = statBuf.st_birthtimespec
//         attributes.addedTime = statBuf.st_atimespec
//         attributes.modifyTime = statBuf.st_mtimespec
//         attributes.accessTime = statBuf.st_atimespec
//         attributes.changeTime = statBuf.st_ctimespec
//         attributes.backupTime = statBuf.st_birthtimespec

//         return attributes
//     }

//     func readData(offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) throws -> Int {
//         // Directories can't be read like files
//         throw fs_errorForPOSIXError(POSIXError.EISDIR.rawValue)
//     }

//     func readSymbolicLink() throws -> FSFileName {
//         // Directories are not symbolic links
//         throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
//     }

//     // MARK: - WriteFSItemProtocol Methods

//     func setAttributes(newAttributes: FSItem.SetAttributesRequest) throws -> FSItem.Attributes {
//         // Handle permissions
//         if newAttributes.isValid(FSItem.Attribute.mode) {
//             try Safe.fchmod(fd: dirFD, mode: mode_t(newAttributes.mode & 0o777))
//         }

//         // Handle ownership
//         if newAttributes.isValid(FSItem.Attribute.uid)
//             || newAttributes.isValid(FSItem.Attribute.gid)
//         {
//             let uid = newAttributes.isValid(FSItem.Attribute.uid) ? newAttributes.uid : ~0
//             let gid = newAttributes.isValid(FSItem.Attribute.gid) ? newAttributes.gid : ~0
//             try Safe.fchown(fd: dirFD, uid: uid, gid: gid)
//         }

//         // Handle timestamps
//         if newAttributes.isValid(FSItem.Attribute.accessTime)
//             || newAttributes.isValid(FSItem.Attribute.modifyTime)
//         {
//             var times = [timespec](
//                 repeating: timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), count: 2)

//             if newAttributes.isValid(FSItem.Attribute.accessTime) {
//                 times[0] = newAttributes.accessTime
//             }

//             if newAttributes.isValid(FSItem.Attribute.modifyTime) {
//                 times[1] = newAttributes.modifyTime
//             }

//             try Safe.futimens(fd: dirFD, times: times)
//         }

//         // Return the updated attributes
//         return try getAttributes()
//     }

//     func writeData(contents: Data, offset: off_t) throws -> Int {
//         // Directories can't be written to like files
//         throw fs_errorForPOSIXError(POSIXError.EISDIR.rawValue)
//     }

//     func removeItem(name: FSFileName) throws {
//         guard let nameStr = name.string else {
//             throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
//         }

//         // Get the child's type
//         var statBuf = stat()
//         try Safe.fstatat(dirfd: dirFD, path: nameStr, statBuf: &statBuf, flags: AT_SYMLINK_NOFOLLOW)

//         let isDir = (statBuf.st_mode & S_IFMT) == S_IFDIR

//         // Remove the item
//         try Safe.unlinkat(dirfd: dirFD, path: nameStr, flags: isDir ? AT_REMOVEDIR : 0)

//         // Update the cache if it exists
//         cachedEntries?.removeValue(forKey: nameStr)
//     }

//     func createLink(to name: FSFileName, inDirectory: FSItem) throws -> FSFileName {
//         throw fs_errorForPOSIXError(POSIXError.ENOTSUP.rawValue)  // Hard links to directories are not supported
//     }

//     func renameItem(
//         inDirectory sourceDirectory: FSItem,
//         named sourceName: FSFileName,
//         to destinationName: FSFileName,
//         inDirectory destinationDirectory: FSItem,
//         overItem: FSItem?
//     ) throws -> FSFileName {
//         guard let sourceNameStr = sourceName.string, let destNameStr = destinationName.string else {
//             throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
//         }

//         // Handle the case where source and destination are in the same directory
//         if sourceDirectory === self && destinationDirectory === self {
//             try Safe.renameat(
//                 fromDirfd: dirFD, fromPath: sourceNameStr,
//                 toDirfd: dirFD, toPath: destNameStr)

//             // Update cache if needed
//             if var entries = cachedEntries, let item = entries.removeValue(forKey: sourceNameStr) {
//                 entries[destNameStr] = item
//                 cachedEntries = entries
//             }

//             return destinationName
//         }

//         // If destination directory is also a PortalDirFSItem, we can use renameat
//         if let destDir = destinationDirectory as? PortalDirFSItem {
//             try Safe.renameat(
//                 fromDirfd: dirFD, fromPath: sourceNameStr,
//                 toDirfd: destDir.dirFD, toPath: destNameStr)

//             // Update cache if needed
//             cachedEntries?.removeValue(forKey: sourceNameStr)

//             return destinationName
//         }

//         // Fallback to less efficient method if dest is not a PortalDirFSItem
//         throw fs_errorForPOSIXError(POSIXError.EXDEV.rawValue)  // Cross-device link not supported in this implementation
//     }

//     func createSymbolicLink(
//         named name: FSFileName,
//         attributes newAttributes: FSItem.SetAttributesRequest,
//         linkContents contents: FSFileName
//     ) throws -> (FSItem, FSFileName) {
//         guard let nameStr = name.string, let targetStr = contents.string else {
//             throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
//         }

//         try Safe.symlinkat(target: targetStr, dirfd: dirFD, path: nameStr)

//         // Set attributes if requested
//         if newAttributes.isValid(FSItem.Attribute.uid)
//             || newAttributes.isValid(FSItem.Attribute.gid)
//             || newAttributes.isValid(FSItem.Attribute.mode)
//         {
//             do {
//                 let fd = try Safe.openat(dirfd: dirFD, path: nameStr, flags: O_RDONLY | O_NOFOLLOW)
//                 defer { try? Safe.closeFD(file: fd) }

//                 if newAttributes.isValid(FSItem.Attribute.uid)
//                     || newAttributes.isValid(FSItem.Attribute.gid)
//                 {
//                     let uid = newAttributes.isValid(FSItem.Attribute.uid) ? newAttributes.uid : ~0
//                     let gid = newAttributes.isValid(FSItem.Attribute.gid) ? newAttributes.gid : ~0
//                     try Safe.fchownat(
//                         dirfd: dirFD, path: nameStr, uid: uid, gid: gid, flags: AT_SYMLINK_NOFOLLOW)
//                 }
//             } catch {
//                 logger.error("Failed to set attributes on symlink: \(error.localizedDescription)")
//             }
//         }

//         do {
//             let itemFD = try Safe.openat(dirfd: dirFD, path: nameStr, flags: O_RDONLY | O_NOFOLLOW)
//             let nextID = fileId.advance(by: UInt64(nameStr.hash & 0x7FFF_FFFF))

//             let item = PortalFileFSItem(
//                 fileId: nextID, parentId: fileId, dirFd: dirFD, fileFd: itemFD.rawValue,
//                 path: nameStr,
//                 itemType: .symlink)

//             // Update cache if needed
//             if cachedEntries != nil {
//                 cachedEntries![nameStr] = item
//             }

//             return (item, name)
//         } catch {
//             throw error
//         }
//     }

//     func createItem(
//         named name: FSFileName,
//         type: FSItem.ItemType,
//         attributes newAttributes: FSItem.SetAttributesRequest
//     ) throws -> (FSItem, FSFileName) {
//         guard let nameStr = name.string else {
//             throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
//         }

//         let nextID = fileId.advance(by: UInt64(nameStr.hash & 0x7FFF_FFFF))
//             let subPath = path.sub(nameStr)

//         switch type {
//         case .directory:
//             // Create directory
//             try Safe.mkdirat(dirfd: dirFD, path: subPath, mode: 0o755)

//             let itemFD = try Safe.openatDirectory(dirfd: dirFD, path: subPath, flags: O_RDONLY)

//             let dirItem = PortalDirFSItem(
//                 fileId: nextID, parentId: fileId, dirFD: itemFD,    path: subPath)

//             // Apply attributes if needed
//             if newAttributes.isValid(FSItem.Attribute.uid)
//                 || newAttributes.isValid(FSItem.Attribute.gid)
//                 || newAttributes.isValid(FSItem.Attribute.mode)
//             {
//                 try _ = dirItem.setAttributes(newAttributes: newAttributes)
//             }

//             // Update cache if needed
//             if cachedEntries != nil {
//                 cachedEntries![nameStr] = dirItem
//             }

//             return (dirItem, name)

//         case .file:
//             // Create file
//             let initialMode: mode_t = 0o644
//             let fd = try Safe.openat(
//                 dirfd: dirFD, path: subPath, flags: O_RDWR | O_CREAT | O_EXCL, mode: initialMode)

//             let fileItem = PortalFileFSItem(
//                 fileId: nextID, parentId: fileId, dirFd: dirFD, fileFd: fd.rawValue, path: subPath,
//                 itemType: .file)

//             // Apply attributes if needed
//             if newAttributes.isValid(FSItem.Attribute.uid)
//                 || newAttributes.isValid(FSItem.Attribute.gid)
//                 || newAttributes.isValid(FSItem.Attribute.mode)
//             {
//                 try _ = fileItem.setAttributes(newAttributes: newAttributes)
//             }

//             // Update cache if needed
//             if cachedEntries != nil {
//                 cachedEntries![nameStr] = fileItem
//             }

//             return (fileItem, name)

//         default:
//             throw fs_errorForPOSIXError(POSIXError.ENOTSUP.rawValue)
//         }
//     }
// }

// /// PortalFileFSItem implements a file that performs operations using a file descriptor
// final class PortalFileFSItem: FSItem, FSItemProtocol, WriteFSItemProtocol {
//     let fileId: FSItem.Identifier
//     let itemType: FSItem.ItemType
//     let parentId: FSItem.Identifier
//     private let dirFd: DirFd
//     private var cachedFd: Int32?
//     private let path: Location
//     private let logger = Logger(subsystem: "FSKitExp", category: "PortalFile")

//     init(
//         fileId: FSItem.Identifier, parentId: FSItem.Identifier, dirFd: DirFd,
//          fileFd: Int32?,
//         path: Location,
//         itemType: FSItem.ItemType
//     ) {
//         self.fileId = fileId
//         self.parentId = parentId
//         self.dirFd = dirFd
//         self.path = path // Changed from fileName to path
//         self.itemType = itemType
//         self.cachedFd = fileFd
//         super.init()
//     }

//     func getFd() throws -> FileFd {
//         if let cachedFd = cachedFd {
//             return FileFd(cachedFd)
//         }

//         let fd = try Safe.openat(dirfd: dirFd, path: path, flags: O_RDONLY)
//         cachedFd = fd.rawValue
//         return fd
//     }

//     deinit {
//         // Close the file descriptor when this object is deallocated
//         if let fd = cachedFd {
//             try? Safe.closeFD(file: FileFd(fd))
//         }
//     }

//     // MARK: - FSItemProtocol Methods

//     func getChildren() throws -> [(FSFileName, FSItemProtocol)] {
//         // Files don't have children
//         throw fs_errorForPOSIXError(POSIXError.ENOTDIR.rawValue)
//     }

//     func getChild(name: FSFileName) throws -> FSItemProtocol? {
//         // Files don't have children
//         throw fs_errorForPOSIXError(POSIXError.ENOTDIR.rawValue)
//     }

//     func getAttributes() throws -> FSItem.Attributes {
//         var statBuf = stat()
//         let fd = try getFd()
//         try Safe.fstat(fd: fd, statBuf: &statBuf)

//         let attributes = FSItem.Attributes()
//         attributes.fileID = fileId
//         attributes.parentID = parentId
//         attributes.type = itemType
//         attributes.uid = statBuf.st_uid
//         attributes.gid = statBuf.st_gid

//         // Set appropriate mode based on item type
//         switch itemType {
//         case .file:
//             attributes.mode = UInt32(statBuf.st_mode & 0o777) | UInt32(S_IFREG)
//         case .symlink:
//             attributes.mode = UInt32(statBuf.st_mode & 0o777) | UInt32(S_IFLNK)
//         default:
//             attributes.mode = UInt32(statBuf.st_mode & 0o777)
//         }

//         attributes.linkCount = UInt32(statBuf.st_nlink)
//         attributes.size = UInt64(statBuf.st_size)
//         attributes.allocSize = UInt64(statBuf.st_blocks * 512)

//         attributes.birthTime = statBuf.st_birthtimespec
//         attributes.modifyTime = statBuf.st_mtimespec
//         attributes.accessTime = statBuf.st_atimespec
//         attributes.changeTime = statBuf.st_ctimespec
//         attributes.addedTime = statBuf.st_atimespec

//         return attributes
//     }

//     func readData(offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) throws -> Int {
//         if itemType == .symlink {
//             throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
//         }

//         // Seek to the requested position
//         let fd = try getFd()
//         try Safe.lseek(fd: fd, offset: offset, whence: SEEK_SET)

//         // Read data
//         return try buffer.withUnsafeMutableBytes { bufferPtr in
//             try Safe.read(
//                 fd: fd, buffer: bufferPtr.baseAddress!, size: min(length, bufferPtr.count))
//         }
//     }

//     func readSymbolicLink() throws -> FSFileName {
//         if itemType != .symlink {
//             throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
//         }

//         // Allocate buffer for link target
//         let bufferSize = Int(PATH_MAX)
//         var buffer = [CChar](repeating: 0, count: bufferSize)

//         // Read symbolic link
//         let result = try Safe.readlinkat(
//             dirfd: dirFd, path: path, buffer: &buffer, size: bufferSize)

//         // Use the recommended string initialization method instead of deprecated one
//         let linkTarget = buffer.withUnsafeBufferPointer { bufferPtr in
//             let bytes = UnsafeRawBufferPointer(start: bufferPtr.baseAddress, count: result)
//             return String(decoding: bytes, as: UTF8.self)
//         }
//         return FSFileName(string: linkTarget)
//     }

//     // MARK: - WriteFSItemProtocol Methods

//     func setAttributes(newAttributes: FSItem.SetAttributesRequest) throws -> FSItem.Attributes {
//         let fd = try getFd()

//         // Handle permissions
//         if newAttributes.isValid(FSItem.Attribute.mode) {
//             try Safe.fchmod(fd: fd, mode: mode_t(newAttributes.mode & 0o777))
//         }

//         // Handle ownership
//         if newAttributes.isValid(FSItem.Attribute.uid)
//             || newAttributes.isValid(FSItem.Attribute.gid)
//         {
//             let uid = newAttributes.isValid(FSItem.Attribute.uid) ? newAttributes.uid : ~0
//             let gid = newAttributes.isValid(FSItem.Attribute.gid) ? newAttributes.gid : ~0
//             try Safe.fchown(fd: fd, uid: uid, gid: gid)
//         }

//         // Handle size (truncate)
//         if newAttributes.isValid(FSItem.Attribute.size) {
//             try Safe.ftruncate(fd: fd, size: off_t(newAttributes.size))
//         }

//         // Handle timestamps
//         if newAttributes.isValid(FSItem.Attribute.accessTime)
//             || newAttributes.isValid(FSItem.Attribute.modifyTime)
//         {
//             var times = [timespec](
//                 repeating: timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), count: 2)

//             if newAttributes.isValid(FSItem.Attribute.accessTime) {
//                 times[0] = newAttributes.accessTime
//             }

//             if newAttributes.isValid(FSItem.Attribute.modifyTime) {
//                 times[1] = newAttributes.modifyTime
//             }

//             try Safe.futimens(fd: fd, times: times)
//         }

//         // Return the updated attributes
//         return try getAttributes()
//     }

//     func writeData(contents: Data, offset: off_t) throws -> Int {
//         if itemType != .file {
//             throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
//         }

//         // Seek to the requested position
//         let fd = try getFd()
//         try Safe.lseek(fd: fd, offset: offset, whence: SEEK_SET)

//         // Write data
//         return try contents.withUnsafeBytes { bufferPtr in
//             try Safe.write(fd: fd, buffer: bufferPtr.baseAddress!, size: bufferPtr.count)
//         }
//     }

//     func removeItem(name: FSFileName, fromDirectory: FSItem) throws {
//         // Files don't have children
//         throw fs_errorForPOSIXError(POSIXError.ENOTDIR.rawValue)
//     }

//     func createLink(to name: FSFileName, inDirectory: FSItem) throws -> FSFileName {
//         guard let destName = name.string,
//             let destDir = inDirectory as? PortalDirFSItem
//         else {
//             throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
//         }

//         // Create hard link from this file to the destination
//         let dirFD = try destDir.getDirectoryFileDescriptor()
//         try Safe.linkat(
//             fromDirfd: dirFd, fromPath: path,
//             toDirfd: dirFD, toPath: destName)

//         return name
//     }

//     func renameItem(
//         inDirectory sourceDirectory: FSItem,
//         named sourceName: FSFileName,
//         to destinationName: FSFileName,
//         inDirectory destinationDirectory: FSItem,
//         overItem: FSItem?
//     ) throws -> FSFileName {
//         // This method shouldn't be called for files
//         throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
//     }

//     func createSymbolicLink(
//         named name: FSFileName,
//         attributes newAttributes: FSItem.SetAttributesRequest,
//         linkContents contents: FSFileName
//     ) throws -> (FSItem, FSFileName) {
//         // Files can't create symbolic links
//         throw fs_errorForPOSIXError(POSIXError.ENOTDIR.rawValue)
//     }

//     func createItem(
//         named name: FSFileName,
//         type: FSItem.ItemType,
//         attributes newAttributes: FSItem.SetAttributesRequest
//     ) throws -> (FSItem, FSFileName) {
//         // Files can't create child items
//         throw fs_errorForPOSIXError(POSIXError.ENOTDIR.rawValue)
//     }
// }

// // Extension to provide access to dirFD which is private
// extension PortalDirFSItem {
//     func getDirectoryFileDescriptor() throws -> DirFd {
//         return dirFD
//     }
// }
