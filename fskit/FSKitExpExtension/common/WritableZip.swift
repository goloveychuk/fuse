import FSKit
import Foundation


func absolutePathToDirname(_ url: URL) -> String {
    return url.path.replacingOccurrences(of: "/", with: "_")
}   

struct WritableConfig {
    let mutationsPath: String
}

final class ThreadSafeSet<T: Hashable>: @unchecked Sendable {
    private var set: Set<T> = []
    private let lock = NSLock()
    func insert(_ element: T) {
        lock.lock()
        set.insert(element)
        lock.unlock()
    }
    func contains(_ element: T) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return set.contains(element)
    }
}

final class WritableZip: PublicZip, Sendable {
    let config: WritableConfig

    let detached = ThreadSafeSet<UInt>()
    let listableZip: ListableZip
    let detachedDir: URL
    init(config: WritableConfig, fileURL: URL) throws {
        self.config = config
        self.detachedDir = URL(fileURLWithPath: config.mutationsPath).appendingPathComponent(
            absolutePathToDirname(fileURL))

        if (FileManager.default.fileExists(atPath: detachedDir.path)) {
            let files = try FileManager.default.contentsOfDirectory(at: detachedDir, includingPropertiesForKeys: nil)
            for file in files {
                detached.insert(UInt(file.lastPathComponent)!)
            }
        }
        self.listableZip = try ListableZip(fileURL: fileURL)
    }
    
    var listable: ListableZip {
        return listableZip
    }

    private func detachedFilePath(_ index: UInt) -> URL {
        return detachedDir.appendingPathComponent("\(index)")
    }

    func statEntry(index: UInt) throws -> ZipStat {
        if detached.contains(index) {
            let stat = listableZip.statEntry(index: index)
            let realStat = try FileManager.default.attributesOfItem(atPath: detachedFilePath(index).path)
            let size = UInt32(realStat[.size] as! UInt64)
            return ZipStat(size: size, allocSize: size, permissions: stat.permissions)
        } else {
            return listableZip.statEntry(index: index)
        }
    }
    func readLink(index: UInt) throws -> Data {
        return try listableZip.readLink(index: index)
    }
    func readData(index: UInt, offset: off_t, length: Int, buffer: MutableBufferLike) throws -> Int {
        if detached.contains(index) {
            let fileHandle = try FileHandle(forReadingFrom: detachedFilePath(index))
            defer {
                try? fileHandle.close()
            }
            try fileHandle.seek(toOffset: UInt64(offset))
            return buffer.withUnsafeMutableBytes { rawBuffer in
                let fd = fileHandle.fileDescriptor
                let bytesRead = read(fd, rawBuffer.baseAddress, min(length, rawBuffer.count))
                return bytesRead > 0 ? Int(bytesRead) : 0
            }
        } else {
            return try listableZip.readData(index: index, offset: offset, length: length, buffer: buffer)
        }
    }

    // I don't do proper locking because write is only for devvelopment usecase
    func writeData(index: UInt, data: Data, offset: off_t) throws -> Int {
        let detachedFile = detachedFilePath(index)

        if !detached.contains(index) {
            try FileManager.default.createDirectory(
                at: detachedDir, withIntermediateDirectories: true)

            let entry = listableZip.getEntry(index: index)
            let length = Int(entry.size)
            let buffer = DataBufferWrapper(capacity: length)

            let read = try listableZip.readData(index: index, offset: 0, length: length, buffer: buffer)
            if read != length {
                throw fs_errorForPOSIXError(POSIXError.EIO)
            }
            try buffer.data.write(to: detachedFile)
            detached.insert(index)
        }
        let fileHandle = try FileHandle(forUpdating: detachedFile)
        defer {
            try? fileHandle.close()
        }

        try fileHandle.seek(toOffset: UInt64(offset))
        try fileHandle.write(contentsOf: data)
        return data.count
    }
}
