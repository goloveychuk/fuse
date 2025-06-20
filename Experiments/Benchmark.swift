import Foundation

import Darwin
import Foundation
import FSKit
enum ZipError: Error {
    case invalidZipFile(String)
    case unsupportedZipFeature(String)
    case zipArchiveInconsistent
    case invalidListing(String)
}
public func fs_errorForPOSIXError(_ err: POSIXErrorCode) -> any Error {
    return NSError(domain: "POSIXError", code: Int(err.rawValue))

}

func decompressDeflate(compressedData: Data, destinationSize: Int) throws -> Data {
    return compressedData
}
public class FSFileName {
    public let data : Data
    public init(data: Data) {
        self.data = data
    }
    public var string: String? {
        return String(data: data, encoding: .utf8)
    }
    public convenience init(string name: String) {
        self.init(data: name.data(using: .utf8)!)
    }

}

struct Indexed<T: Sendable>: Sendable {
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

enum ZipID: Hashable, Sendable {
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

public protocol MutableBufferLike {
    var length: Int {get}
    func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R
}

public class DataBufferWrapper: MutableBufferLike {
    var data: Data
    public var length: Int
    public init(capacity: Int) {
        self.data = Data(capacity: capacity)
        self.length = capacity
    }
    public func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        return try body(data.withUnsafeMutableBytes { $0 })
    }
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



protocol PublicZip: Sendable {
    func statEntry(index: UInt) throws -> ZipStat
    func readLink(index: UInt) throws -> Data
    func readData(index: UInt, offset: off_t, length: Int, buffer: MutableBufferLike) throws -> Int
    func writeData(index: UInt, data: Data, offset: off_t) throws -> Int
    var listable: ListableZip { get }
} 


final class ListableZip : PublicZip, Sendable {

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

    var listable: ListableZip {
        return self
    }

    func getIdForPath(path: ZipPath) throws -> ZipID {
        var currentId: ZipID = .root
        for part in path.splitPath() {
            if part.isEmpty {
                continue
            }
            guard case .dir(let listingId) = currentId else {
                throw fs_errorForPOSIXError(POSIXError.ENOTDIR)
            }
            let list = listings[Int(listingId)]
            guard let childId = list[part.filename] else {
                throw fs_errorForPOSIXError(POSIXError.ENOENT)
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
            throw fs_errorForPOSIXError(POSIXError.EIO)
        }
        return try rawReadAllDataIntoBuffer(index: index)
    }

    func writeData(index: UInt, data: Data, offset: off_t) throws -> Int {
        throw fs_errorForPOSIXError(POSIXError.EROFS)
    }

    func statEntry(index: UInt) -> ZipStat {
        let entry = getEntry(index: index)
        return ZipStat(size: entry.size, allocSize: entry.compressedSize, permissions: entry.permissions)
    }

    public func readData(index: UInt, offset: off_t, length: Int, buffer: MutableBufferLike) throws -> Int {
        if (buffer.length != length) {
            throw fs_errorForPOSIXError(POSIXError.EIO) //todo
        }
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
                    if bytesRead > 0 {  //todo think
                        return bytesRead
                    } else {
                        throw fs_errorForPOSIXError(POSIXError.EIO)
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
            throw fs_errorForPOSIXError(POSIXError.EIO)
        }
        return data
    }

    private func rawReadData(
        index: UInt, offset: Int, length: Int, bufferPointer: UnsafeMutableRawBufferPointer
    )  throws -> Int {
        let entry = getEntry(index: index)
        
        // Memory map the file
        let mappedData = try Data(contentsOf: fileURL, options: .mappedRead)
        
        return try mappedData.withUnsafeBytes { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: UInt8.self)
            
            // Read local header (first 30 bytes)
            let localHeaderOffset = Int(entry.localHeaderOffset)
            if localHeaderOffset + 30 > mappedData.count {
                throw ZipError.invalidZipFile("Could not read local header")
            }
            
            // Get pointer to the local header
            let localHeaderPtr = buffer.baseAddress!.advanced(by: localHeaderOffset)
            
            // Parse header fields directly from memory
            let nameLength = localHeaderPtr.advanced(by: 26).withMemoryRebound(to: UInt16.self, capacity: 1) {
                $0.pointee.littleEndian
            }
            
            let extraLength = localHeaderPtr.advanced(by: 28).withMemoryRebound(to: UInt16.self, capacity: 1) {
                $0.pointee.littleEndian
            }
    
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
            
            // Calculate the exact position of data in the file
            let startPos = Int(dataOffset) + offset
            
            // Make sure we're not reading beyond the file
            if startPos + bytesToRead > mappedData.count {
                throw ZipError.invalidZipFile("Attempt to read beyond end of file")
            }
            
            // Get direct pointer to the data in memory
            let dataPtr = buffer.baseAddress!.advanced(by: startPos)
            
            // Copy data directly from memory-mapped file to output buffer
            memcpy(bufferPointer.baseAddress!, dataPtr, bytesToRead)
            
            return bytesToRead
        }
    }

    func getParentForZipID(zipID: ZipID) -> ZipID? { //nil returned for root node
        if (zipID == .root) {
            return nil
        }
        return .dir(listingId: UInt(parentMapping[zipID]!))
    }


    init(fileURL: URL) async throws {
        self.fileURL = fileURL
        let entries = try await ListableZip.readZipEntries(fileURL: fileURL)
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

    static func readZipEntries(fileURL: URL) async throws -> [ZipEntry] {
        // Memory map the entire file
        let mappedData = try Data(contentsOf: fileURL, options: .mappedRead)
        let fileSize = mappedData.count
        
        if fileSize < noCommentCDSize {
            throw ZipError.invalidZipFile("EOCD not found")
        }

        var eocdOffset: Int = -1
        var eocdBaseOffset: Int = 0

        return try mappedData.withUnsafeBytes { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: UInt8.self)
            
            // Fast read if no comment
            let eocdStartOffset = fileSize - noCommentCDSize
            
            if eocdStartOffset >= 0 {
                let signature = buffer.baseAddress!.advanced(by: eocdStartOffset).withMemoryRebound(to: UInt32.self, capacity: 1) { 
                    return $0.pointee.littleEndian
                }
                
                if signature == END_OF_CENTRAL_DIRECTORY {
                    eocdOffset = 0
                    eocdBaseOffset = eocdStartOffset
                }
            }
    
            // If not found, do a more extensive search
            if eocdOffset == -1 {
                let bufferSize = min(65557, fileSize)
                let searchStartOffset = max(0, fileSize - bufferSize)
                
                // Find EOCD signature
                for i in stride(from: fileSize - 4, through: searchStartOffset, by: -1) {
                    let signature = buffer.baseAddress!.advanced(by: i).withMemoryRebound(to: UInt32.self, capacity: 1) {
                        return $0.pointee.littleEndian
                    }
                    
                    if signature == END_OF_CENTRAL_DIRECTORY {
                        eocdOffset = 0
                        eocdBaseOffset = i
                        break
                    }
                }
    
                if eocdOffset == -1 {
                    throw ZipError.invalidZipFile("Not a zip archive")
                }
            }
    
            // Parse EOCD fields
            let eocdPtr = buffer.baseAddress!.advanced(by: eocdBaseOffset)
            let totalEntries = eocdPtr.advanced(by: 10).withMemoryRebound(to: UInt16.self, capacity: 1) { 
                $0.pointee.littleEndian
            }
            
            let centralDirSize = eocdPtr.advanced(by: 12).withMemoryRebound(to: UInt32.self, capacity: 1) { 
                $0.pointee.littleEndian
            }
            
            let centralDirOffset = eocdPtr.advanced(by: 16).withMemoryRebound(to: UInt32.self, capacity: 1) { 
                $0.pointee.littleEndian
            }
            
            let commentLength = eocdPtr.advanced(by: 20).withMemoryRebound(to: UInt16.self, capacity: 1) { 
                $0.pointee.littleEndian
            }
    
            // Consistency checks
            if eocdOffset + Int(commentLength) + noCommentCDSize > (fileSize - eocdBaseOffset) {
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
    
            // Verify central directory boundaries
            let cdEndOffset = Int(centralDirOffset) + Int(centralDirSize)
            if cdEndOffset > fileSize {
                throw ZipError.zipArchiveInconsistent
            }
            
            // Create pointer to central directory
            let cdPtr = buffer.baseAddress!.advanced(by: Int(centralDirOffset))

            var entries: [ZipEntry] = []
            entries.reserveCapacity(Int(totalEntries))
            var offset = 0
            var index = 0
            var sumCompressedSize: UInt32 = 0
            // return entries
            while index < totalEntries {
                if offset + 46 > Int(centralDirSize) {
                    throw ZipError.zipArchiveInconsistent
                }
                
                // Get pointer to current entry
                let entryPtr = cdPtr.advanced(by: offset)
                
                // Read entry header fields directly from memory
                let signature = entryPtr.withMemoryRebound(to: UInt32.self, capacity: 1) {
                    $0.pointee.littleEndian
                }
                
                if signature != CENTRAL_DIRECTORY {
                    throw ZipError.zipArchiveInconsistent
                }

                let versionMadeBy = entryPtr.advanced(by: 4).withMemoryRebound(to: UInt16.self, capacity: 1) {
                    $0.pointee.littleEndian
                }
                let os = UInt8(versionMadeBy >> 8)

                let flags = entryPtr.advanced(by: 8).withMemoryRebound(to: UInt16.self, capacity: 1) {
                    $0.pointee.littleEndian
                }
                if (flags & 0x0001) != 0 {
                    throw ZipError.unsupportedZipFeature("Encrypted zip files are not supported")
                }

                let compressionMethodValue = entryPtr.advanced(by: 10).withMemoryRebound(to: UInt16.self, capacity: 1) {
                    $0.pointee.littleEndian
                }
                let compressionMethod = CompressionMethod(rawValue: compressionMethodValue)
                guard let compressionMethod = compressionMethod else {
                    throw ZipError.invalidZipFile("Not supported zip compression")
                }
                
                let crc = entryPtr.advanced(by: 16).withMemoryRebound(to: UInt32.self, capacity: 1) {
                    $0.pointee.littleEndian
                }
                
                let compressedSize = entryPtr.advanced(by: 20).withMemoryRebound(to: UInt32.self, capacity: 1) {
                    $0.pointee.littleEndian
                }
                
                let size = entryPtr.advanced(by: 24).withMemoryRebound(to: UInt32.self, capacity: 1) {
                    $0.pointee.littleEndian
                }
                
                let nameLength = entryPtr.advanced(by: 28).withMemoryRebound(to: UInt16.self, capacity: 1) {
                    $0.pointee.littleEndian
                }
                
                let extraLength = entryPtr.advanced(by: 30).withMemoryRebound(to: UInt16.self, capacity: 1) {
                    $0.pointee.littleEndian
                }
                
                let commentLength = entryPtr.advanced(by: 32).withMemoryRebound(to: UInt16.self, capacity: 1) {
                    $0.pointee.littleEndian
                }
                
                let externalAttributes = entryPtr.advanced(by: 38).withMemoryRebound(to: UInt32.self, capacity: 1) {
                    $0.pointee.littleEndian
                }
                
                let localHeaderOffset = entryPtr.advanced(by: 42).withMemoryRebound(to: UInt32.self, capacity: 1) {
                    $0.pointee.littleEndian
                }

                // Extract name directly from memory without copying
                var nameData = Data()
                if nameLength > 0 {
                    // We need to copy the name data since we can't hold raw pointers beyond this function
                    let namePtr = entryPtr.advanced(by: 46)
                    nameData = Data(bytes: namePtr, count: Int(nameLength))
                }

                // 31                    16 15            0
                // +----------------------+---------------+
                // | Unix file mode bits  |  MS-DOS attrs |
                // +----------------------+---------------+
                //      (high 16 bits)      (low 16 bits)

                let linuxAttributes = mode_t(externalAttributes >> 16)

                let isSymbolicLink =
                    os == ZIP_UNIX && (linuxAttributes & S_IFMT) == S_IFLNK

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

            if offset != Int(centralDirSize) {
                throw ZipError.zipArchiveInconsistent
            }

            return entries
        }
    }
}


func benchmark() async {
    print("Running ListableZip benchmark...")
    let homeDir = FileManager.default.homeDirectoryForCurrentUser
    let yarnCachePath = homeDir.appendingPathComponent(".yarn/berry/cache")
    
    do {
        // Get list of all files in directory
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: yarnCachePath,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles
        )
        
        // Filter for zip files
        let zipFiles = fileURLs.filter { $0.pathExtension.lowercased() == "zip" }
        print("Found \(zipFiles.count) zip files in ~/.yarn/cache/berry")
        
        if zipFiles.isEmpty {
            print("No zip files found in the directory.")
            return
        }
        
        // Start timing
        let startTime = Date()
        var successCount = 0
        var failCount = 0
        
        // Process each zip file
        for (index, zipURL) in zipFiles.enumerated() {
            do {
                // Try to open the zip file
                // let zip = try await ListableZip(fileURL: zipURL)
                let _ = try await ListableZip.readZipEntries(fileURL: zipURL)
                successCount += 1
                
                // Optional: Print progress every 10 files
                // if index % 10 == 0 {
                //     print("Processed \(index)/\(zipFiles.count) files...")
                // }
            } catch {
                failCount += 1
                print("Error opening \(zipURL.lastPathComponent): \(error)")
            }
        }
        
        // Calculate elapsed time
        let timeElapsed = Date().timeIntervalSince(startTime)
        
        // Print results
        print("Benchmark complete!")
        print("Time elapsed: \(timeElapsed) seconds")
        print("Successfully opened: \(successCount) files")
        print("Failed to open: \(failCount) files")
        print("Average time per file: \(timeElapsed / Double(zipFiles.count)) seconds")
        
    } catch {
        print("Error accessing directory: \(error)")
    }
}

// Run the benchmark
Task {
    await benchmark()
}

// Keep the process running until benchmark completes
RunLoop.main.run(until: Date(timeIntervalSinceNow: 60)) 