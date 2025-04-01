import Foundation

enum ZipSignature {
    static let CENTRAL_DIRECTORY: UInt32 = 0x02014b50
    static let END_OF_CENTRAL_DIRECTORY: UInt32 = 0x06054b50
}

let ZIP_UNIX: UInt8 = 3
let noCommentCDSize = 22

enum ZipConstants {
    static let SAFE_TIME: Date = Date(timeIntervalSince1970: 456789000)
    static let S_IFMT: UInt32 = 0xF000  // File type mask
    static let S_IFLNK: UInt32 = 0xA000 // Symbolic link
}

enum ZipError: Error {
    case invalidZipFile(String)
    case unsupportedZipFeature(String)
    case zipArchiveInconsistent
}

extension Data {
    func loadLittleEndian<T: FixedWidthInteger>(_ offset: Int, as type: T.Type) -> T {
        return withUnsafeBytes { $0.load(fromByteOffset: offset, as: type).littleEndian }
    }
}

struct ZipEntry {
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

struct ZipEntryIterator: IteratorProtocol, Sequence {
    typealias Element = ZipEntry
    
    private var entries: [ZipEntry]
    private var index: Int = 0
    
    init(entries: [ZipEntry]) {
        self.entries = entries
    }
    
    mutating func next() -> ZipEntry? {
        guard index < entries.count else {
            return nil
        }
        defer { index += 1 }
        return entries[index]
    }
    
    func makeIterator() -> ZipEntryIterator {
        return self
    }
}

class ZipReader {
    
    static func readZip(fileURL: URL) throws -> [ZipEntry] {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? fileHandle.close()
        }
        
        let fileSize = try fileHandle.seekToEnd() // todo stat
        
        if fileSize < UInt64(noCommentCDSize) {
            throw ZipError.invalidZipFile("EOCD not found")
        }
        
        var eocdOffset: Int = -1
        
        // Fast read if no comment
        try fileHandle.seek(toOffset: fileSize - UInt64(noCommentCDSize))
        var eocdBuffer = try  fileHandle.read(upToCount: noCommentCDSize) ?? Data()
        
        if eocdBuffer.count == noCommentCDSize {
            let signature = eocdBuffer.loadLittleEndian(0, as: UInt32.self)
            if signature == ZipSignature.END_OF_CENTRAL_DIRECTORY {
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
                if signature == ZipSignature.END_OF_CENTRAL_DIRECTORY {
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
        
        if totalEntries == 0xffff || centralDirSize == 0xffffffff || centralDirOffset == 0xffffffff {
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
            if signature != ZipSignature.CENTRAL_DIRECTORY {
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
            guard let name = String(data: nameData, encoding: .utf8)?.replacingOccurrences(of: "\0", with: " ") else {
                throw ZipError.invalidZipFile("Invalid ZIP file")
            }
            
            if name.contains("\0") {
                throw ZipError.invalidZipFile("Invalid ZIP file")
            }
            
            let isSymbolicLink = os == ZIP_UNIX && ((externalAttributes >> 16) & ZipConstants.S_IFMT) == ZipConstants.S_IFLNK
            
            entries.append(ZipEntry(
                name: name,
                compressionMethod: compressionMethod,
                size: size,
                os: os,
                isSymbolicLink: isSymbolicLink,
                crc: crc,
                compressedSize: compressedSize,
                externalAttributes: externalAttributes,
                mtime: ZipConstants.SAFE_TIME,
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
