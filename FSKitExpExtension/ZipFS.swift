import Darwin
import Foundation

enum ZipError: Error {
    case invalidZipFile(String)
    case unsupportedZipFeature(String)
    case zipArchiveInconsistent
    case invalidListing(String)
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

struct ZipEntry {  //todo minimal
    let name: String
    let compressionMethod: UInt16
    let size: UInt32
    let os: UInt8
    let isSymbolicLink: Bool
    let crc: UInt32
    let compressedSize: UInt32
    let externalAttributes: UInt32
    let mtime: Date
    let localHeaderOffset: UInt32
}

enum ZipID {
    case noChildren
    case ind(Int)
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

class ListableZip {

    private static let SAFE_TIME: Date = Date(timeIntervalSince1970: 456_789_000)
    // static let S_IFMT: UInt32 = 0xF000  // File type mask
    // static let S_IFLNK: UInt32 = 0xA000 // Symbolic link
    private static let ZIP_UNIX: UInt8 = 3
    private static let noCommentCDSize = 22
    private static let CENTRAL_DIRECTORY: UInt32 = 0x0201_4b50
    private static let END_OF_CENTRAL_DIRECTORY: UInt32 = 0x0605_4b50

    private let allEntries: [ZipEntry]

    private let childrenMap: [[PathSegment: ZipID]]

    init(fileURL: URL) throws {
        let entries = try ListableZip.readZipEntries(fileURL: fileURL)
        allEntries = entries
        var childrenMap = [[PathSegment: ZipID]]()

        var nameToIdMap: [String: ZipID] = [String: ZipID]()
        func addEntry(parent: String, child: String?) throws -> ZipID {
            var ind: ZipID
            if let id = nameToIdMap[parent] {
                ind = id
            } else {
                let newIndex = ZipID.ind(childrenMap.count)
                nameToIdMap[parent] = newIndex
                childrenMap.append([:])
                ind = newIndex
            }
            if let child = child {
                var childId: ZipID
                if (child.last != "/") {
                    childId = ZipID.noChildren
                } else {
                    childId = try addEntry(parent: parent+"/"+child, child: nil)
                }
                guard case .ind(let ind) = ind else {
                    throw ZipError.invalidListing("Cannot set children for file")
                }
                childrenMap[ind][child] = childId
            }
            return ind
        }

        _ = try addEntry(parent: "/", child: nil)

        for entry in entries {
            var (parent, name) = entry.name.splitOnceFromRight(separator: "/")
            if name == nil || name == "" {
                name = parent
                parent = "/"
            }
            _ = try addEntry(parent: parent, child: name)

            // childrenMap[parent]

            // let parent =
        }
        self.childrenMap = childrenMap
    }

    private static func readZipEntries(fileURL: URL) throws -> [ZipEntry] {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? fileHandle.close()
        }
        // Get file size using stat on the file descriptor
        var statInfo = stat()
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

        if totalEntries > UInt16(centralDirSize / 46) {
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

            let compressionMethod = cdBuffer.loadLittleEndian(offset + 10, as: UInt16.self)
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
            guard
                let name = String(data: nameData, encoding: .utf8)?.replacingOccurrences(
                    of: "\0", with: " ")
            else {
                throw ZipError.invalidZipFile("Invalid ZIP file")
            }

            if name.contains("\0") {
                throw ZipError.invalidZipFile("Invalid ZIP file")
            }

            let isSymbolicLink =
                os == ZIP_UNIX && ((UInt16(externalAttributes >> 16)) & S_IFMT) == S_IFLNK  //todo check UInt16()

            entries.append(
                ZipEntry(
                    name: name,
                    compressionMethod: compressionMethod,
                    size: size,
                    os: os,
                    isSymbolicLink: isSymbolicLink,
                    crc: crc,
                    compressedSize: compressedSize,
                    externalAttributes: externalAttributes,
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
