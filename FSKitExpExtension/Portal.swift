import Darwin
import FSKit
import Foundation
import System

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

/// PortalDirFSItem implements a directory that performs operations relative to a directory file descriptor
final class PortalDirFSItem: FSItem, FSItemProtocol, WriteFSItemProtocol {
    let fileId: FSItem.Identifier
    let itemType: FSItem.ItemType = .directory
    let parentId: FSItem.Identifier
    private let dirFD: Int32
    private var cachedEntries: [String: FSItemProtocol]?
    private let logger = Logger(subsystem: "FSKitExp", category: "PortalDir")

    init(fileId: FSItem.Identifier, parentId: FSItem.Identifier, dirFD: Int32) {
        self.fileId = fileId
        self.parentId = parentId
        self.dirFD = dirFD
        super.init()
    }

    deinit {
        // Close the directory file descriptor when this object is deallocated
        if dirFD >= 0 {
            Darwin.close(dirFD)
        }
    }

    // MARK: - FSItemProtocol Methods

    func getChildren() throws -> [(FSFileName, FSItemProtocol)] {
        if let entries = cachedEntries {
            return entries.map { (FSFileName(string: $0.key), $0.value) }
        }

        // Duplicate the FD to avoid closing the original when fdopendir takes ownership
        let tempFD = dup(dirFD)
        if tempFD == -1 {
            throw fs_errorForPOSIXError(errno)
        }

        guard let dir = fdopendir(tempFD) else {
            close(tempFD)  // Close the duplicate if fdopendir fails
            throw fs_errorForPOSIXError(errno)
        }

        defer { closedir(dir) }
        rewinddir(dir)

        var entries = [String: FSItemProtocol]()
        var nextID = fileId.advance(by: 1)

        while let entry = readdir(dir) {
            // Get entry name
            let name = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
            }

            // Skip . and ..
            if name == "." || name == ".." {
                continue
            }

            let type: FSItem.ItemType

            // Determine type from d_type if available
            switch entry.pointee.d_type {
            case UInt8(DT_DIR):
                type = .directory
            case UInt8(DT_REG):
                type = .file
            case UInt8(DT_LNK):
                type = .symlink
            default:
                // If d_type is unknown, use fstatat to determine
                var statBuf = stat()
                let entryPath = name
                if fstatat(dirFD, entryPath, &statBuf, AT_SYMLINK_NOFOLLOW) == 0 {
                    if (statBuf.st_mode & S_IFMT) == S_IFDIR {
                        type = .directory
                    } else if (statBuf.st_mode & S_IFMT) == S_IFREG {
                        type = .file
                    } else if (statBuf.st_mode & S_IFMT) == S_IFLNK {
                        type = .symlink
                    } else {
                        continue  // Skip unknown types
                    }
                } else {
                    continue  // Skip if stat fails
                }
            }

            if type == .directory {
                // Open subdirectory with O_DIRECTORY
                let itemFD = openat(dirFD, name, O_RDONLY | O_DIRECTORY, 0)
                if itemFD >= 0 {
                    entries[name] = PortalDirFSItem(
                        fileId: nextID, parentId: fileId, dirFD: itemFD)
                }
            } else {
                // Open file

                entries[name] = PortalFileFSItem(
                    fileId: nextID, parentId: fileId, dirFd: dirFD, fileFd: nil, name: name,
                    itemType: type)

            }

            nextID = nextID.advance(by: 1)
        }

        cachedEntries = entries
        return entries.map { (FSFileName(string: $0.key), $0.value) }
    }

    func getChild(name: FSFileName) throws -> FSItemProtocol? {
        guard let nameStr = name.string else {
            return nil
        }

        // Try getting from cache first
        if let entries = cachedEntries, let item = entries[nameStr] {
            return item
        }

        // Otherwise, open the file to check if it exists and determine its type
        var statBuf = stat()
        if fstatat(dirFD, nameStr, &statBuf, AT_SYMLINK_NOFOLLOW) != 0 {
            return nil  // File doesn't exist
        }

        // let childPath = dirPath + "/" + nameStr
        let nextID = fileId.advance(by: UInt64(nameStr.hash & 0x7FFF_FFFF))

        let type: FSItem.ItemType
        if (statBuf.st_mode & S_IFMT) == S_IFDIR {
            type = .directory
            let newFD = openat(dirFD, nameStr, O_RDONLY | O_DIRECTORY, 0)
            if newFD >= 0 {
                return PortalDirFSItem(
                    fileId: nextID, parentId: fileId, dirFD: newFD)
            }
        } else if (statBuf.st_mode & S_IFMT) == S_IFREG {
            type = .file

            return PortalFileFSItem(
                fileId: nextID, parentId: fileId, dirFd: dirFD, fileFd: nil, name: nameStr,
                itemType: type)

        } else if (statBuf.st_mode & S_IFMT) == S_IFLNK {
            type = .symlink

            return PortalFileFSItem(
                fileId: nextID, parentId: fileId, dirFd: dirFD, fileFd: nil, name: nameStr,
                itemType: type)

        }

        return nil
    }

    func getAttributes() throws -> FSItem.Attributes {
        var statBuf = stat()
        if fstat(dirFD, &statBuf) != 0 {
            throw fs_errorForPOSIXError(errno)
        }

        let attributes = FSItem.Attributes()
        attributes.fileID = fileId
        attributes.parentID = parentId
        attributes.type = .directory
        attributes.uid = statBuf.st_uid
        attributes.gid = statBuf.st_gid
        attributes.mode = UInt32(statBuf.st_mode & 0o777) | UInt32(S_IFDIR)
        attributes.linkCount = UInt32(statBuf.st_nlink)
        attributes.size = UInt64(statBuf.st_size)
        attributes.allocSize = UInt64(statBuf.st_blocks * 512)

        attributes.birthTime = statBuf.st_birthtimespec
        attributes.addedTime = statBuf.st_atimespec
        attributes.modifyTime = statBuf.st_mtimespec
        attributes.accessTime = statBuf.st_atimespec
        attributes.changeTime = statBuf.st_ctimespec
        attributes.backupTime = statBuf.st_birthtimespec

        return attributes
    }

    func readData(offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) throws -> Int {
        // Directories can't be read like files
        throw fs_errorForPOSIXError(POSIXError.EISDIR.rawValue)
    }

    func readSymbolicLink() throws -> FSFileName {
        // Directories are not symbolic links
        throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
    }

    // MARK: - WriteFSItemProtocol Methods

    func setAttributes(newAttributes: FSItem.SetAttributesRequest) throws -> FSItem.Attributes {
        // Handle permissions
        if newAttributes.isValid(FSItem.Attribute.mode) {
            if fchmod(dirFD, mode_t(newAttributes.mode & 0o777)) != 0 {
                throw fs_errorForPOSIXError(errno)
            }
        }

        // Handle ownership
        if newAttributes.isValid(FSItem.Attribute.uid)
            || newAttributes.isValid(FSItem.Attribute.gid)
        {
            let uid = newAttributes.isValid(FSItem.Attribute.uid) ? newAttributes.uid : ~0
            let gid = newAttributes.isValid(FSItem.Attribute.gid) ? newAttributes.gid : ~0
            if fchown(dirFD, uid, gid) != 0 {
                throw fs_errorForPOSIXError(errno)
            }
        }

        // Handle timestamps
        if newAttributes.isValid(FSItem.Attribute.accessTime)
            || newAttributes.isValid(FSItem.Attribute.modifyTime)
        {
            var times = [timespec](
                repeating: timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), count: 2)

            if newAttributes.isValid(FSItem.Attribute.accessTime) {
                times[0] = newAttributes.accessTime
            }

            if newAttributes.isValid(FSItem.Attribute.modifyTime) {
                times[1] = newAttributes.modifyTime
            }

            if futimens(dirFD, times) != 0 {
                throw fs_errorForPOSIXError(errno)
            }
        }

        // Return the updated attributes
        return try getAttributes()
    }

    func writeData(contents: Data, offset: off_t) throws -> Int {
        // Directories can't be written to like files
        throw fs_errorForPOSIXError(POSIXError.EISDIR.rawValue)
    }

    func removeItem(name: FSFileName, fromDirectory: FSItem) throws {
        guard let nameStr = name.string else {
            throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
        }

        // Get the child's type
        var statBuf = stat()
        if fstatat(dirFD, nameStr, &statBuf, AT_SYMLINK_NOFOLLOW) != 0 {
            throw fs_errorForPOSIXError(errno)
        }

        let isDir = (statBuf.st_mode & S_IFMT) == S_IFDIR

        // Remove the item
        if unlinkat(dirFD, nameStr, isDir ? AT_REMOVEDIR : 0) != 0 {
            throw fs_errorForPOSIXError(errno)
        }

        // Update the cache if it exists
        cachedEntries?.removeValue(forKey: nameStr)
    }

    func createLink(to name: FSFileName, inDirectory: FSItem) throws -> FSFileName {
        throw fs_errorForPOSIXError(POSIXError.ENOTSUP.rawValue)  // Hard links to directories are not supported
    }

    func renameItem(
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?
    ) throws -> FSFileName {
        guard let sourceNameStr = sourceName.string, let destNameStr = destinationName.string else {
            throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
        }

        // Handle the case where source and destination are in the same directory
        if sourceDirectory === self && destinationDirectory === self {
            if renameat(dirFD, sourceNameStr, dirFD, destNameStr) != 0 {
                throw fs_errorForPOSIXError(errno)
            }

            // Update cache if needed
            if var entries = cachedEntries, let item = entries.removeValue(forKey: sourceNameStr) {
                entries[destNameStr] = item
                cachedEntries = entries
            }

            return destinationName
        }

        // If destination directory is also a PortalDirFSItem, we can use renameat2
        if let destDir = destinationDirectory as? PortalDirFSItem {
            if renameat(dirFD, sourceNameStr, destDir.dirFD, destNameStr) != 0 {
                throw fs_errorForPOSIXError(errno)
            }

            // Update cache if needed
            cachedEntries?.removeValue(forKey: sourceNameStr)

            return destinationName
        }

        // Fallback to less efficient method if dest is not a PortalDirFSItem
        throw fs_errorForPOSIXError(POSIXError.EXDEV.rawValue)  // Cross-device link not supported in this implementation
    }

    func createSymbolicLink(
        named name: FSFileName,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName
    ) throws -> (FSItem, FSFileName) {
        guard let nameStr = name.string, let targetStr = contents.string else {
            throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
        }

        if symlinkat(targetStr, dirFD, nameStr) != 0 {
            throw fs_errorForPOSIXError(errno)
        }

        // Set attributes if requested
        if newAttributes.isValid(FSItem.Attribute.uid)
            || newAttributes.isValid(FSItem.Attribute.gid)
            || newAttributes.isValid(FSItem.Attribute.mode)
        {
            let fd = openat(dirFD, nameStr, O_RDONLY | O_NOFOLLOW, 0)
            if fd >= 0 {
                defer { close(fd) }

                if newAttributes.isValid(FSItem.Attribute.uid)
                    || newAttributes.isValid(FSItem.Attribute.gid)
                {
                    let uid = newAttributes.isValid(FSItem.Attribute.uid) ? newAttributes.uid : ~0
                    let gid = newAttributes.isValid(FSItem.Attribute.gid) ? newAttributes.gid : ~0
                    fchownat(dirFD, nameStr, uid, gid, AT_SYMLINK_NOFOLLOW)
                }
            }
        }

        let itemFD = openat(dirFD, nameStr, O_RDONLY | O_NOFOLLOW, 0)
        let nextID = fileId.advance(by: UInt64(nameStr.hash & 0x7FFF_FFFF))

        if itemFD >= 0 {
            let item = PortalFileFSItem(
                fileId: nextID, parentId: fileId, dirFd: dirFD, fileFd: itemFD, name: nameStr,
                itemType: .symlink)

            // Update cache if needed
            if cachedEntries != nil {
                cachedEntries![nameStr] = item
            }

            return (item, name)
        } else {
            throw fs_errorForPOSIXError(errno)
        }
    }

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        attributes newAttributes: FSItem.SetAttributesRequest
    ) throws -> (FSItem, FSFileName) {
        guard let nameStr = name.string else {
            throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
        }

        let nextID = fileId.advance(by: UInt64(nameStr.hash & 0x7FFF_FFFF))

        switch type {
        case .directory:
            // Create directory
            if mkdirat(dirFD, nameStr, 0o755) != 0 {
                throw fs_errorForPOSIXError(errno)
            }

            let itemFD = openat(dirFD, nameStr, O_RDONLY | O_DIRECTORY, 0)
            if itemFD < 0 {
                throw fs_errorForPOSIXError(errno)
            }

            let dirItem = PortalDirFSItem(
                fileId: nextID, parentId: fileId, dirFD: itemFD)

            // Apply attributes if needed
            if newAttributes.isValid(FSItem.Attribute.uid)
                || newAttributes.isValid(FSItem.Attribute.gid)
                || newAttributes.isValid(FSItem.Attribute.mode)
            {
                try _ = dirItem.setAttributes(newAttributes: newAttributes)
            }

            // Update cache if needed
            if cachedEntries != nil {
                cachedEntries![nameStr] = dirItem
            }

            return (dirItem, name)

        case .file:
            // Create file
            let initialMode: mode_t = 0o644
            let fd = openat(dirFD, nameStr, O_RDWR | O_CREAT | O_EXCL, initialMode)
            if fd < 0 {
                throw fs_errorForPOSIXError(errno)
            }

            let fileItem = PortalFileFSItem(
                fileId: nextID, parentId: fileId, dirFd: dirFD, fileFd: fd, name: nameStr,
                itemType: .file)

            // Apply attributes if needed
            if newAttributes.isValid(FSItem.Attribute.uid)
                || newAttributes.isValid(FSItem.Attribute.gid)
                || newAttributes.isValid(FSItem.Attribute.mode)
            {
                try _ = fileItem.setAttributes(newAttributes: newAttributes)
            }

            // Update cache if needed
            if cachedEntries != nil {
                cachedEntries![nameStr] = fileItem
            }

            return (fileItem, name)

        default:
            throw fs_errorForPOSIXError(POSIXError.ENOTSUP.rawValue)
        }
    }
}

/// PortalFileFSItem implements a file that performs operations using a file descriptor
final class PortalFileFSItem: FSItem, FSItemProtocol, WriteFSItemProtocol {
    let fileId: FSItem.Identifier
    let itemType: FSItem.ItemType
    let parentId: FSItem.Identifier
    private let dirFd: Int32
    private var cachedFd: Int32?
    private let fileName: String
    private let logger = Logger(subsystem: "FSKitExp", category: "PortalFile")

    init(
        fileId: FSItem.Identifier, parentId: FSItem.Identifier, dirFd: Int32, fileFd: Int32?,
        name: String,
        itemType: FSItem.ItemType
    ) {
        self.fileId = fileId
        self.parentId = parentId
        self.dirFd = dirFd
        self.fileName = name
        self.itemType = itemType
        self.cachedFd = fileFd
        super.init()
    }

    func getFd() throws -> Int32 {
        guard let cachedFd = cachedFd else {
            cachedFd = openat(dirFd, fileName, O_RDONLY, 0)
            if cachedFd == -1 {
                logger.error(
                    "Failed to open file descriptor for \(self.fileName)"
                )
                throw fs_errorForPOSIXError(errno)
            }
            return cachedFd!
        }

        return cachedFd
    }
    deinit {
        // Close the file descriptor when this object is deallocated
        if let fd = cachedFd {
            Darwin.close(fd)
        }
    }

    // MARK: - FSItemProtocol Methods

    func getChildren() throws -> [(FSFileName, FSItemProtocol)] {
        // Files don't have children
        throw fs_errorForPOSIXError(POSIXError.ENOTDIR.rawValue)
    }

    func getChild(name: FSFileName) throws -> FSItemProtocol? {
        // Files don't have children
        throw fs_errorForPOSIXError(POSIXError.ENOTDIR.rawValue)
    }

    func getAttributes() throws -> FSItem.Attributes {
        var statBuf = stat()
        if fstat(try getFd(), &statBuf) != 0 {
            throw fs_errorForPOSIXError(errno)
        }

        let attributes = FSItem.Attributes()
        attributes.fileID = fileId
        attributes.parentID = parentId
        attributes.type = itemType
        attributes.uid = statBuf.st_uid
        attributes.gid = statBuf.st_gid

        // Set appropriate mode based on item type
        switch itemType {
        case .file:
            attributes.mode = UInt32(statBuf.st_mode & 0o777) | UInt32(S_IFREG)
        case .symlink:
            attributes.mode = UInt32(statBuf.st_mode & 0o777) | UInt32(S_IFLNK)
        default:
            attributes.mode = UInt32(statBuf.st_mode & 0o777)
        }

        attributes.linkCount = UInt32(statBuf.st_nlink)
        attributes.size = UInt64(statBuf.st_size)
        attributes.allocSize = UInt64(statBuf.st_blocks * 512)

        attributes.birthTime = statBuf.st_birthtimespec
        attributes.modifyTime = statBuf.st_mtimespec
        attributes.accessTime = statBuf.st_atimespec
        attributes.changeTime = statBuf.st_ctimespec
        attributes.addedTime = statBuf.st_atimespec

        return attributes
    }

    func readData(offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) throws -> Int {
        if itemType == .symlink {
            throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
        }

        // Seek to the requested position
        if lseek(try getFd(), offset, SEEK_SET) == -1 {
            throw fs_errorForPOSIXError(errno)
        }

        // Read data
        return try buffer.withUnsafeMutableBytes { bufferPtr in
            let bytesRead = Darwin.read(
                try getFd(), bufferPtr.baseAddress, min(length, bufferPtr.count))
            return bytesRead >= 0 ? bytesRead : -1
        }
    }

    func readSymbolicLink() throws -> FSFileName {
        if itemType != .symlink {
            throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
        }

        // Allocate buffer for link target
        let bufferSize = Int(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: bufferSize)

        // Read symbolic link
        let result = readlinkat(dirFd, fileName, &buffer, bufferSize)
        
        guard result != -1 else {
            throw fs_errorForPOSIXError(errno)
        }

        // Use the recommended string initialization method instead of deprecated one
        let linkTarget = buffer.withUnsafeBufferPointer { bufferPtr in
            let bytes = UnsafeRawBufferPointer(start: bufferPtr.baseAddress, count: result)
            return String(decoding: bytes, as: UTF8.self)
        }
        return FSFileName(string: linkTarget)
    }

    // MARK: - WriteFSItemProtocol Methods

    func setAttributes(newAttributes: FSItem.SetAttributesRequest) throws -> FSItem.Attributes {
        // Handle permissions
        if newAttributes.isValid(FSItem.Attribute.mode) {
            if fchmod(try getFd(), mode_t(newAttributes.mode & 0o777)) != 0 {
                throw fs_errorForPOSIXError(errno)
            }
        }

        // Handle ownership
        if newAttributes.isValid(FSItem.Attribute.uid)
            || newAttributes.isValid(FSItem.Attribute.gid)
        {
            let uid = newAttributes.isValid(FSItem.Attribute.uid) ? newAttributes.uid : ~0
            let gid = newAttributes.isValid(FSItem.Attribute.gid) ? newAttributes.gid : ~0
            if fchown(try getFd(), uid, gid) != 0 {
                throw fs_errorForPOSIXError(errno)
            }
        }

        // Handle size (truncate)
        if newAttributes.isValid(FSItem.Attribute.size) {
            if ftruncate(try getFd(), off_t(newAttributes.size)) != 0 {
                throw fs_errorForPOSIXError(errno)
            }
        }

        // Handle timestamps
        if newAttributes.isValid(FSItem.Attribute.accessTime)
            || newAttributes.isValid(FSItem.Attribute.modifyTime)
        {
            var times = [timespec](
                repeating: timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), count: 2)

            if newAttributes.isValid(FSItem.Attribute.accessTime) {
                times[0] = newAttributes.accessTime
            }

            if newAttributes.isValid(FSItem.Attribute.modifyTime) {
                times[1] = newAttributes.modifyTime
            }

            if futimens(try getFd(), times) != 0 {
                throw fs_errorForPOSIXError(errno)
            }
        }

        // Return the updated attributes
        return try getAttributes()
    }

    func writeData(contents: Data, offset: off_t) throws -> Int {
        if itemType != .file {
            throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
        }

        // Seek to the requested position
        if lseek(try getFd(), offset, SEEK_SET) == -1 {
            throw fs_errorForPOSIXError(errno)
        }

        // Write data
        return try contents.withUnsafeBytes { bufferPtr in
            let bytesWritten = Darwin.write(try getFd(), bufferPtr.baseAddress, bufferPtr.count)
            return bytesWritten >= 0 ? bytesWritten : -1
        }
    }

    func removeItem(name: FSFileName, fromDirectory: FSItem) throws {
        // Files don't have children
        throw fs_errorForPOSIXError(POSIXError.ENOTDIR.rawValue)
    }

    func createLink(to name: FSFileName, inDirectory: FSItem) throws -> FSFileName {
        guard let destName = name.string,
            let destDir = inDirectory as? PortalDirFSItem
        else {
            throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
        }

        // Create hard link from this file to the destination
        // Access the dirFD through a publicly defined method - we'll need to create one
        let dirFD = try destDir.getDirectoryFileDescriptor()
        if linkat(dirFd, fileName, dirFD, destName, 0) != 0 {
            throw fs_errorForPOSIXError(errno)
        }

        return name
    }

    func renameItem(
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?
    ) throws -> FSFileName {
        // This method shouldn't be called for files
        throw fs_errorForPOSIXError(POSIXError.EINVAL.rawValue)
    }

    func createSymbolicLink(
        named name: FSFileName,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName
    ) throws -> (FSItem, FSFileName) {
        // Files can't create symbolic links
        throw fs_errorForPOSIXError(POSIXError.ENOTDIR.rawValue)
    }

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        attributes newAttributes: FSItem.SetAttributesRequest
    ) throws -> (FSItem, FSFileName) {
        // Files can't create child items
        throw fs_errorForPOSIXError(POSIXError.ENOTDIR.rawValue)
    }
}

// Extension to provide access to dirFD which is private
extension PortalDirFSItem {
    func getDirectoryFileDescriptor() throws -> Int32 {
        return dirFD
    }
}
