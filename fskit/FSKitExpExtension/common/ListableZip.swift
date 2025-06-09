import Foundation
import FSKit
enum ZipError: Error {
    case invalidZipFile(String)
    case unsupportedZipFeature(String)
    case zipArchiveInconsistent
    case invalidListing(String)
}

struct Indexed<T> {
    typealias Key = FSFileName

    private var items: [Data: T] = [:]

    init() {
        self.items = [:]
    }

    func entries() -> [(Key, T)] {
        return items.lazy.map { (FSFileName(data: $0.key), $0.value) } //todo ceheck lazy
    }

    // private func findIndex(for key: Key) -> Int? {
    //     var low = 0
    //     var high = items.count - 1

    //     while low <= high {
    //         let mid = (low + high) / 2
    //         let midKey = items[mid].0

    //         if midKey == key {
    //             return mid
    //         } else if midKey < key {
    //             low = mid + 1
    //         } else {
    //             high = mid - 1
    //         }
    //     }

    //     return nil
    // }

    // private func insertionPoint(for key: Key) -> Int {
    //     var low = 0
    //     var high = items.count - 1

    //     while low <= high {
    //         let mid = (low + high) / 2

    //         if items[mid].0 < key {
    //             low = mid + 1
    //         } else {
    //             high = mid - 1
    //         }
    //     }

    //     return low
    // }

    subscript(index: Key) -> T? {
        return items[index.data]
        // if let foundIndex = findIndex(for: index) {
        //     return items[foundIndex].1
        // }
        // return nil
    }

    subscript(index: Key) -> T {
        get {
            return items[index.data]!

            // if let foundIndex = findIndex(for: index) {
            //     return items[foundIndex].1
            // }
            // fatalError("Index not found")
        }
        set(newValue) {
            items[index.data] = newValue
            // if let existingIndex = findIndex(for: index) {
            //     items[existingIndex] = (index, newValue)
            // } else {
            //     let insertAt = insertionPoint(for: index)
            //     items.insert((index, newValue), at: insertAt)
            // }
        }
    }
}

extension Data {
    //todo check all loadLittleEndian calls
    func loadLittleEndian<T: FixedWidthInteger>(_ offset: Int, as type: T.Type) -> T {
        return withUnsafeBytes { rawBuffer in
            return rawBuffer.loadUnaligned(fromByteOffset: offset, as: T.self).littleEndian
        }
    }
    //  func loadLittleEndian<T: FixedWidthInteger>(_ offset: Int, as type: T.Type) -> T {
    //     let size = MemoryLayout<T>.size
    //     return withUnsafeBytes { rawBuffer -> T in
    //         let pointer = rawBuffer.baseAddress!.advanced(by: offset)
    //         if Int(bitPattern: pointer) % MemoryLayout<T>.alignment == 0 {
    //             // Aligned: use direct load
    //             return pointer.load(as: T.self).littleEndian
    //         } else {
    //             // Not aligned: fall back to manual reading
    //             var value: T = 0
    //             for i in 0..<size {
    //                 let byte = T(rawBuffer[offset + i])
    //                 value |= byte << (8 * i)
    //             }
    //             return T(littleEndian: value)
    //         }
    //     }
    // }
}

enum CompressionMethod {
    case store
    case deflate
    init?(rawValue: UInt16) {
        switch rawValue {
        case 0:
            self = .store
        case 8:
            self = .deflate
        default:
            return nil
        }
    }
}



struct ZipEntry {  //todo minimal
    let name: ZipPath
    let compressionMethod: CompressionMethod
    let size: UInt32
    let os: UInt8
    let isSymbolicLink: Bool
    let crc: UInt32
    let compressedSize: UInt32
    let linuxAttributes: mode_t
    let mtime: Date
    let localHeaderOffset: UInt32
}

typealias Permissions = mode_t
extension Permissions {
    init(fromUnsafe: mode_t) {
        self = Permissions(fromUnsafe & 0b111_111_111) // getting standard rwx permissions
    }
}

enum ZipID: Hashable {
    case file(entryId: UInt)
    case symlink(entryId: UInt)
    case dir(listingId: UInt)
    static var root: ZipID {
        return .dir(listingId: 0)
    }
}

typealias ZipPath = Data
typealias ZipPathSegment = Data

extension ZipPath {
    private static let slash: UInt8 = 0x2f
    static let Root = Data([slash])
    // Debug representation of path
    var asd: String {
        if self == ZipPath.Root {
            return "/"
        }
        return String(data: self, encoding: .utf8) ?? "<invalid UTF-8 data>"
    }
    
    // Convert path to String for display
    var pathString: String {
        return String(data: self, encoding: .utf8) ?? ""
    }
    func splitPath() -> [ZipPathSegment] {
        var segments: [ZipPathSegment] = []
        var currentSegment: [UInt8] = []

        for byte in self {
            if byte == ZipPath.slash {
                if !currentSegment.isEmpty {
                    segments.append(Data(currentSegment))
                    currentSegment.removeAll()
                }
            } else {
                currentSegment.append(byte)
            }
        }

        if !currentSegment.isEmpty {
            segments.append(Data(currentSegment))
        }

        return segments
    }
    init(path: String) {
        self.init(path.utf8)
    }
    func splitPathParent() -> (ZipPathSegment, ZipPathSegment) {
        // check for short empty and slash
        var to = self.count - 1
        for i in stride(from: self.count - 1, through: 0, by: -1) {
            if self[i] == ZipPath.slash {
                if (i == self.count - 1) {
                    to -= 1
                    continue
                }
                let parentPath = self[0...i]
                let last = self[(i + 1)...to]
                return (parentPath, last)
            }
        }
        return (Data([ZipPath.slash]), self[0...to])
    }
    func isDir() -> Bool {
        return self.last == ZipPath.slash
    }
    var filename: FSFileName {
        return FSFileName(data: self)
    }
}

extension String {
    /// Splits the string once from the right side based on the given separator
    /// Returns a tuple with the part before the separator and the part after the separator
    /// If the separator is not found, returns the whole string as the first element and nil as the second
    func splitOnceFromRight(separator: Character) -> (String, String?) {
        guard let lastIndex = self.lastIndex(of: separator) else {
            return (self, nil)
        }

        let firstPart = String(self[..<lastIndex])
        let secondPart = String(self[self.index(after: lastIndex)...])

        return (firstPart, secondPart)
    }
}

typealias Listings = [Indexed<ZipID>]

// extension Listings {
//     func print(ind: Int = 0, depth: Int = 0) -> String {
//         var result = ""
//         for item in self[ind] {
//             let key = item.key
//             let value = item.value
//             result += String(repeating: "   ", count: depth) + "\(key):\n"
//             if case .dir(let index) = value {
//                 result += self.print(ind: index, depth: depth + 1)
//             }
//         }
//         return result
//     }
// }

protocol MutableBufferLike {
    func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R
}

class DataBufferWrapper: MutableBufferLike {
    var data: Data
    var length: Int
    init(capacity: Int) {
        self.data = Data(capacity: capacity)
        self.length = capacity
    }
    func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        return try body(data.withUnsafeMutableBytes { $0 })
    }
}

extension FSMutableFileDataBuffer: MutableBufferLike {
}

struct MinEntry {
    let localHeaderOffset: UInt32
    let compressedSize: UInt32
    let size: UInt32
    let permissions: Permissions
    let compressionMethod: CompressionMethod
}

struct ZipStat {
    let size: UInt32
    let allocSize: UInt32
    let permissions: Permissions
}

protocol PublicZip {
    func stat(index: UInt) throws -> ZipStat
    func readLink(index: UInt) throws -> Data
    func readData(index: UInt, offset: off_t, length: Int, buffer: MutableBufferLike) throws -> Int
    func writeData(index: UInt, data: Data, offset: off_t) throws -> Int
} 


class ListableZip : PublicZip {

    private static let SAFE_TIME: Date = Date(timeIntervalSince1970: 456_789_000)
    // static let S_IFMT: UInt32 = 0xF000  // File type mask
    // static let S_IFLNK: UInt32 = 0xA000 // Symbolic link
    private static let ZIP_UNIX: UInt8 = 3
    private static let noCommentCDSize = 22
    private static let CENTRAL_DIRECTORY: UInt32 = 0x0201_4b50
    private static let END_OF_CENTRAL_DIRECTORY: UInt32 = 0x0605_4b50

    private let allEntries: [MinEntry] 
    private let parentMapping: [ZipID: Int]
    private let listings: Listings
    private let fileURL: URL

    func getIdForPath(path: ZipPath) throws -> ZipID {
        var currentId: ZipID = .root
        for part in path.splitPath() {
            if part.isEmpty {
                continue
            }
            guard case .dir(let listingId) = currentId else {
                throw ZipError.invalidListing("Invalid path, not dir")
            }
            let list = listings[Int(listingId)]
            guard let childId = list[part.filename] else {
                throw ZipError.invalidListing("Invalid path, cannot found child \(part)")
            }
            currentId = childId
        }
        return currentId
    }

    func getChildren(forId: ZipID) -> Indexed<ZipID> {
        guard case .dir(let index) = forId else {
            return Indexed() //todo throw
        }
        return listings[Int(index)]
    }

    public func getEntry(index: UInt) -> MinEntry {
        return allEntries[Int(index)]
    }

    public func readLink(index: UInt) throws -> Data {
        let zipEntry = getEntry(index: index)
        if zipEntry.compressionMethod != .store {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        return try rawReadAllDataIntoBuffer(index: index)
    }

    func writeData(index: UInt, data: Data, offset: off_t) throws -> Int {
        throw fs_errorForPOSIXError(POSIXError.EROFS.rawValue)
    }

    func stat(index: UInt) -> ZipStat {
        let entry = getEntry(index: index)
        return ZipStat(size: entry.size, allocSize: entry.compressedSize, permissions: entry.permissions)
    }

    public func readData(index: UInt, offset: off_t, length: Int, buffer: MutableBufferLike) throws -> Int {
        let zipEntry = getEntry(index: index)
            switch zipEntry.compressionMethod {
            case .deflate:
                let compressedData = try rawReadAllDataIntoBuffer(
                    index: index)

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
                    let bytesRead = try rawReadData(
                        index: index,
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
    }

    private func rawReadAllDataIntoBuffer(index: UInt)  throws -> Data {
        let zipEntry = getEntry(index: index)
        var data = Data(capacity: Int(zipEntry.compressedSize))
        let read = try  data.withUnsafeMutableBytes { (body:UnsafeMutableRawBufferPointer)  throws -> Int in
            return try rawReadData(
                index: index, offset: 0, length: Int(zipEntry.compressedSize),
                bufferPointer: body)
        }
        if read != zipEntry.compressedSize {
            throw fs_errorForPOSIXError(POSIXError.EIO.rawValue)
        }
        return data
    }

    private func rawReadData(
        index: UInt, offset: Int, length: Int, bufferPointer: UnsafeMutableRawBufferPointer
    )  throws -> Int {
        let entry = getEntry(index: index)

        // Open the file where the zip is stored
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? fileHandle.close()
        }

        // Read local header
        try fileHandle.seek(toOffset: UInt64(entry.localHeaderOffset))
        guard let localHeaderBuf = try fileHandle.read(upToCount: 30) else {
            throw ZipError.invalidZipFile("Could not read local header")
        }

        if localHeaderBuf.count < 30 {
            throw ZipError.invalidZipFile("Incomplete local header")
        }

        // Parse header fields
        let nameLength = localHeaderBuf.loadLittleEndian(26, as: UInt16.self)
        let extraLength = localHeaderBuf.loadLittleEndian(28, as: UInt16.self)

        // Calculate offset to compressed data
        let dataOffset = entry.localHeaderOffset + 30 + UInt32(nameLength) + UInt32(extraLength)

        // Validate offset
        if offset < 0 || offset >= entry.compressedSize {
            return 0
        }

        // Calculate how many bytes to read based on offset, length, and compressed size
        let bytesToRead = min(length, Int(entry.compressedSize) - offset)
        if bytesToRead <= 0 {
            return 0
        }

        // Make sure the buffer has enough space
        let bufferCapacity = min(bytesToRead, bufferPointer.count)
        if bufferCapacity <= 0 {
            return 0
        }

        // Seek to the correct position (data offset + requested offset)
        try fileHandle.seek(toOffset: UInt64(dataOffset) + UInt64(offset))

        let bytesRead = read(
            fileHandle.fileDescriptor,
            bufferPointer.baseAddress!,
            bufferCapacity)

        return bytesRead
        // // Read directly into the provided buffer
        // guard let readData = try fileHandle.read(upToCount: bufferCapacity) else {
        //     return 0
        // }

        // // Copy read data to the buffer
        // readData.copyBytes(to: bufferPointer)
        // return readData.count

    }

    func getParentForZipID(zipID: ZipID) -> ZipID? { //nil returned for root node
        if (zipID == .root) {
            return nil
        }
        return .dir(listingId: UInt(parentMapping[zipID]!))
    }


    init(fileURL: URL) throws {
        self.fileURL = fileURL
        let entries = try ListableZip.readZipEntries(fileURL: fileURL)
        var listings = Listings()
        var parentMapping = [ZipID: Int]()
        var allEntries = [MinEntry]()

        var nameToIndMap = [ZipPathSegment: Int]()

        func addDirectory(parent: ZipPathSegment) throws -> ZipID {
            if nameToIndMap[parent] != nil {
                throw ZipError.invalidListing("Directory already exists")
            }
            let newIndex = ZipID.dir(listingId: UInt(listings.count))
            nameToIndMap[parent] = listings.count
            listings.append(Indexed())
            return newIndex
        }

        func addListings(parent: ZipPath, childName: ZipPath, childID: ZipID) throws {
            guard let parentId = nameToIndMap[parent] else {
                throw ZipError.invalidListing("Parent directory not found")
            }
            listings[parentId][childName.filename] = childID
            parentMapping[childID] = parentId
        }

        _ = try addDirectory(parent: ZipPath.Root)

        for entry in entries {
            let isDir = entry.name.isDir()
            var zipID: ZipID
            if isDir {
                zipID = try addDirectory(parent: entry.name)
            } else {
                let ind = allEntries.count
                allEntries.append(
                    MinEntry(
                        localHeaderOffset: entry.localHeaderOffset,
                        compressedSize: entry.compressedSize,
                        size: entry.size,
                        permissions: Permissions(fromUnsafe: entry.linuxAttributes),
                        compressionMethod: entry.compressionMethod,
                    )
                )

                if entry.isSymbolicLink {
                    zipID = ZipID.symlink(entryId: UInt(ind))
                } else {
                    zipID = ZipID.file(entryId: UInt(ind))
                }
            }
            let (parent, name) = entry.name.splitPathParent()
            try addListings(parent: parent, childName: name, childID: zipID)
        }
        // let stringified = listings.print()
        self.listings = listings
        self.parentMapping = parentMapping
        self.allEntries = allEntries
    }

    private static func readZipEntries(fileURL: URL) throws -> [ZipEntry] {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? fileHandle.close()
        }
        // Get file size using stat on the file descriptor
        var statInfo = Darwin.stat()
        if fstat(fileHandle.fileDescriptor, &statInfo) != 0 {
            throw ZipError.invalidZipFile("Could not determine file size")
        }
        let fileSize = UInt64(statInfo.st_size)

        if fileSize < UInt64(noCommentCDSize) {
            throw ZipError.invalidZipFile("EOCD not found")
        }

        var eocdOffset: Int = -1

        // Fast read if no comment
        try fileHandle.seek(toOffset: fileSize - UInt64(noCommentCDSize))
        var eocdBuffer = try fileHandle.read(upToCount: noCommentCDSize) ?? Data()

        if eocdBuffer.count == noCommentCDSize {
            let signature = eocdBuffer.loadLittleEndian(0, as: UInt32.self)
            if signature == END_OF_CENTRAL_DIRECTORY {
                eocdOffset = 0
            }
        }

        // If not found, do a more extensive search
        if eocdOffset == -1 {
            let bufferSize = min(65557, Int(fileSize))
            try fileHandle.seek(toOffset: UInt64(max(0, Int(fileSize) - bufferSize)))
            eocdBuffer = try fileHandle.read(upToCount: bufferSize) ?? Data()

            // Find EOCD signature
            for i in stride(from: eocdBuffer.count - 4, through: 0, by: -1) {
                let signature = eocdBuffer.loadLittleEndian(i, as: UInt32.self)
                if signature == END_OF_CENTRAL_DIRECTORY {
                    eocdOffset = i
                    break
                }
            }

            if eocdOffset == -1 {
                throw ZipError.invalidZipFile("Not a zip archive")
            }
        }

        // Parse EOCD fields
        let totalEntries = eocdBuffer.loadLittleEndian(eocdOffset + 10, as: UInt16.self)
        let centralDirSize = eocdBuffer.loadLittleEndian(eocdOffset + 12, as: UInt32.self)
        let centralDirOffset = eocdBuffer.loadLittleEndian(eocdOffset + 16, as: UInt32.self)
        let commentLength = eocdBuffer.loadLittleEndian(eocdOffset + 20, as: UInt16.self)

        // Consistency checks
        if eocdOffset + Int(commentLength) + noCommentCDSize > eocdBuffer.count {
            throw ZipError.zipArchiveInconsistent
        }

        if totalEntries == 0xffff || centralDirSize == 0xffff_ffff
            || centralDirOffset == 0xffff_ffff
        {
            throw ZipError.unsupportedZipFeature("Zip 64 is not supported")
        }

        if centralDirSize > UInt32(fileSize) {
            throw ZipError.zipArchiveInconsistent
        }

        if UInt32(totalEntries) > centralDirSize / 46 {
            throw ZipError.zipArchiveInconsistent
        }

        // Read central directory
        try fileHandle.seek(toOffset: UInt64(centralDirOffset))
        let cdBuffer = try fileHandle.read(upToCount: Int(centralDirSize)) ?? Data()

        if cdBuffer.count != Int(centralDirSize) {
            throw ZipError.zipArchiveInconsistent
        }

        var entries: [ZipEntry] = []
        var offset = 0
        var index = 0
        var sumCompressedSize: UInt32 = 0

        while index < totalEntries {
            if offset + 46 > cdBuffer.count {
                throw ZipError.zipArchiveInconsistent
            }

            let signature = cdBuffer.loadLittleEndian(offset, as: UInt32.self)
            if signature != CENTRAL_DIRECTORY {
                throw ZipError.zipArchiveInconsistent
            }

            let versionMadeBy = cdBuffer.loadLittleEndian(offset + 4, as: UInt16.self)
            let os = UInt8(versionMadeBy >> 8)

            let flags = cdBuffer.loadLittleEndian(offset + 8, as: UInt16.self)
            if (flags & 0x0001) != 0 {
                throw ZipError.unsupportedZipFeature("Encrypted zip files are not supported")
            }

            let compressionMethod = CompressionMethod(
                rawValue: cdBuffer.loadLittleEndian(offset + 10, as: UInt16.self))
            guard let compressionMethod = compressionMethod else {
                throw ZipError.invalidZipFile("Not supported zip compression")
            }
            let crc = cdBuffer.loadLittleEndian(offset + 16, as: UInt32.self)
            let compressedSize = cdBuffer.loadLittleEndian(offset + 20, as: UInt32.self)
            let size = cdBuffer.loadLittleEndian(offset + 24, as: UInt32.self)
            let nameLength = cdBuffer.loadLittleEndian(offset + 28, as: UInt16.self)
            let extraLength = cdBuffer.loadLittleEndian(offset + 30, as: UInt16.self)
            let commentLength = cdBuffer.loadLittleEndian(offset + 32, as: UInt16.self)
            let externalAttributes = cdBuffer.loadLittleEndian(offset + 38, as: UInt32.self)
            let localHeaderOffset = cdBuffer.loadLittleEndian(offset + 42, as: UInt32.self)

            // Extract name
            let nameData = cdBuffer.subdata(in: (offset + 46)..<(offset + 46 + Int(nameLength)))
            //todo check for \0???
            // guard
            //     let name = String(data: nameData, encoding: .utf8)?.replacingOccurrences(
            //         of: "\0", with: " ")
            // else {
            //     throw ZipError.invalidZipFile("Invalid ZIP file")
            // }

            // if name.contains("\0") {
            //     throw ZipError.invalidZipFile("Invalid ZIP file")
            // }

            // 31                    16 15            0
            // +----------------------+---------------+
            // | Unix file mode bits  |  MS-DOS attrs |
            // +----------------------+---------------+
            //      (high 16 bits)      (low 16 bits)

            let linuxAttributes = mode_t(externalAttributes >> 16) //todo check if linux

            let isSymbolicLink =
                os == ZIP_UNIX && (linuxAttributes & S_IFMT) == S_IFLNK  //todo check UInt16()

            //todo check
            // let isDir =
            //     os == ZIP_UNIX && ((UInt16(externalAttributes >> 16)) & S_IFMT) == S_IFDIR  //todo check UInt16()

            entries.append(
                ZipEntry(
                    name: nameData,
                    compressionMethod: compressionMethod,
                    size: size,
                    os: os,
                    isSymbolicLink: isSymbolicLink,
                    crc: crc,
                    compressedSize: compressedSize,
                    linuxAttributes: linuxAttributes,
                    mtime: SAFE_TIME,
                    localHeaderOffset: localHeaderOffset
                ))

            sumCompressedSize += compressedSize

            index += 1
            offset += 46 + Int(nameLength) + Int(extraLength) + Int(commentLength)
        }

        // Check for archive bombs
        if sumCompressedSize > UInt32(fileSize) {
            throw ZipError.zipArchiveInconsistent
        }

        if offset != cdBuffer.count {
            throw ZipError.zipArchiveInconsistent
        }

        return entries
    }
}
