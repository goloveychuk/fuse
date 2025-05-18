import FSKit
import Foundation
import Glibc
import clibfuse
import common

// MARK: - Low-level FUSE Operations

// let ll_init: @convention(c) (UnsafeMutablePointer<fuse_conn_info>?, UnsafeMutablePointer<fuse_config>?) -> UnsafeMutableRawPointer? = { conn, cfg in
//     print("Filesystem initialized")

//     if let cfg = cfg {
//         cfg.pointee.kernel_cache = 1
//     }

//     return Unmanaged.passRetained(FilesystemState.shared).toOpaque()
// }

// let ll_destroy: @convention(c) (UnsafeMutableRawPointer?) -> Void = { userdata in
//     print("Filesystem destroyed")

//     if let userdata = userdata {
//         Unmanaged<FilesystemState>.fromOpaque(userdata).release()
//     }
// }

// let ll_lookup: @convention(c) (fuse_ino_t, UnsafePointer<Int8>?, UnsafeMutablePointer<fuse_entry_param>?) -> Void = { parent, name, entry_param in
//     guard let name = name, let entry_param = entry_param else { return }

//     let nameStr = String(cString: name)
//     print("lookup: parent=\(parent), name=\(nameStr)")

//     // Clear entry param
//     memset(entry_param, 0, MemoryLayout<fuse_entry_param>.size)

//     // Get parent node
//     guard let parentNode = FilesystemState.shared.getNode(inode: UInt64(parent)) else {
//         entry_param.pointee.ino = 0
//         return
//     }

//     // Handle special cases
//     if nameStr == "." {
//         entry_param.pointee.ino = fuse_ino_t(parentNode.inode)
//         parentNode.fillStat(&entry_param.pointee.attr)
//         entry_param.pointee.attr_timeout = 1.0
//         entry_param.pointee.entry_timeout = 1.0
//         // Increase ref count
//         _ = Unmanaged<FsNode>.fromOpaque(UnsafeRawPointer(bitPattern: Int(parentNode.inode))!).retain()
//         return
//     }

//     if nameStr == ".." {
//         let parentIno = parentNode.parent
//         entry_param.pointee.ino = fuse_ino_t(parentIno)
//         if let grandparentNode = FilesystemState.shared.getNode(inode: parentIno) {
//             grandparentNode.fillStat(&entry_param.pointee.attr)
//             // Increase ref count
//             if let ptr = UnsafeRawPointer(bitPattern: Int(parentIno)) {
//                 _ = Unmanaged<FsNode>.fromOpaque(ptr).retain()
//             }
//         }
//         entry_param.pointee.attr_timeout = 1.0
//         entry_param.pointee.entry_timeout = 1.0
//         return
//     }

//     // Look for the requested node
//     for (_, childNode) in parentNode.children {
//         if childNode.name == nameStr {
//             entry_param.pointee.ino = fuse_ino_t(childNode.inode)
//             childNode.fillStat(&entry_param.pointee.attr)
//             entry_param.pointee.attr_timeout = 1.0
//             entry_param.pointee.entry_timeout = 1.0
//             // Increase ref count for the found node
//             _ = Unmanaged<FsNode>.fromOpaque(UnsafeRawPointer(bitPattern: Int(childNode.inode))!).retain()
//             return
//         }
//     }

//     // Not found
// //     entry_param.pointee.ino = 0
// // }

// let ll_getattr: @convention(c) (fuse_ino_t, UnsafeMutablePointer<stat>?, UnsafeMutablePointer<fuse_file_info>?) -> Int32 = { ino, stbuf, fi in
//     guard let stbuf = stbuf else { return -EINVAL }

//     print("getattr: ino=\(ino)")

//     guard let node = FilesystemState.shared.getNode(inode: UInt64(ino)) else {
//         return -ENOENT
//     }

//     node.fillStat(stbuf)
//     return 0
// }

// let ll_readdir: @convention(c) (fuse_ino_t, size_t, off_t, UnsafeMutablePointer<fuse_file_info>?,
//                                fuse_readdir_callback?, UnsafeMutableRawPointer?) -> Int32 = { ino, size, off, fi, filler, buf in
//     print("readdir: ino=\(ino), offset=\(off)")

//     guard let node = FilesystemState.shared.getNode(inode: UInt64(ino)),
//           node.type == .directory,
//           let filler = filler,
//           let buf = buf else {
//         return -ENOENT
//     }

//     var offset: off_t = 0

//     // Skip entries based on offset
//     if offset >= off {
//         var stat_buf = stat()
//         node.fillStat(&stat_buf)
//         if filler(buf, ".", &stat_buf, offset + 1, 0) != 0 {
//             return 0
//         }
//     }
//     offset += 1

//     if offset >= off {
//         var stat_buf = stat()
//         if let parentNode = FilesystemState.shared.getNode(inode: node.parent) {
//             parentNode.fillStat(&stat_buf)
//         }
//         if filler(buf, "..", &stat_buf, offset + 1, 0) != 0 {
//             return 0
//         }
//     }
//     offset += 1

//     // List children
//     for (_, childNode) in node.children {
//         if offset >= off {
//             var stat_buf = stat()
//             childNode.fillStat(&stat_buf)
//             if filler(buf, childNode.name, &stat_buf, offset + 1, 0) != 0 {
//                 return 0
//             }
//         }
//         offset += 1
//     }

//     return 0
// }

// let ll_forget: @convention(c) (fuse_ino_t, UInt64) -> Void = { ino, nlookup in
//     print("forget: ino=\(ino), nlookup=\(nlookup)")

//     // Skip root inode and other special cases
//     if ino == FUSE_ROOT_ID || ino <= 1 {
//         return
//     }

//     let ptr = UnsafeRawPointer(bitPattern: Int(ino))
//     guard let ptr = ptr else { return }

//     // Release the node nlookup times
//     for _ in 0..<nlookup {
//         Unmanaged<FsNode>.fromOpaque(ptr).release()
//     }

//     // Remove from cache if needed
//     FilesystemState.shared.nodeCache.removeValue(forKey: UInt64(ino))
// }

// let ll_open: @convention(c) (fuse_ino_t, UnsafeMutablePointer<fuse_file_info>?) -> Int32 = { ino, fi in
//     guard let node = FilesystemState.shared.getNode(inode: UInt64(ino)) else {
//         return -ENOENT
//     }

//     if node.type == .directory {
//         return -EISDIR
//     }

//     if let fi = fi {
//         fi.pointee.fh = UInt64(ino)
//     }

//     return 0
// }

// let ll_read: @convention(c) (fuse_ino_t, size_t, off_t, UnsafeMutablePointer<fuse_file_info>?, UnsafeMutablePointer<Int8>?, size_t) -> Int32 = { ino, size, off, fi, buf, bufsize in
//     guard let node = FilesystemState.shared.getNode(inode: UInt64(ino)),
//           node.type == .file,
//           let buf = buf else {
//         return -ENOENT
//     }

//     let content = node.content ?? Data()
//     let contentSize = content.count

//     if off >= contentSize {
//         return 0
//     }

//     let readSize = min(Int(size), contentSize - Int(off))
//     content.withUnsafeBytes { rawBuffer in
//         let sourcePtr = rawBuffer.baseAddress!.advanced(by: Int(off))
//         memcpy(buf, sourcePtr, readSize)
//     }

//     return Int32(readSize)
// }

// MARK: - Main Function

// class LLFS {
//     let lala = "asd"
//     var readdirplus: (@convention(c) (fuse_req_t?, fuse_ino_t, Int, off_t, UnsafeMutablePointer<fuse_file_info>?) -> Void)! = { (req, ino, idk, offset, fileInfo) in
//         // self.lal
//     }
// }

class Context {
    var rootNode: FSItem?
}

let context = Context()


@MainActor
func main() throws {
    print("Starting low-level FUSE filesystem...")

    // let llfs = LLFS()
    // Initialize operations structure
    var operations = fuse_lowlevel_ops()
    // operations.init = ll_init
    // operations.destroy = ll_destroy
    // operations.lookup = ll_lookup
    operations.getattr = { (req, ino, fi) in
        print("getattr: ino=\(ino)")

        // Define a dummy stat structure
        var stbuf = stat()
        memset(&stbuf, 0, MemoryLayout<stat>.size)

        // Set dummy attributes
        stbuf.st_ino = ino_t(ino)
        stbuf.st_mode = S_IFDIR | 0o755
        stbuf.st_nlink = 2
        stbuf.st_size = 0

        // Reply with the attributes
        fuse_reply_attr(req, &stbuf, 1.0)
    }
    operations.readdirplus = { (req, ino, size, off, fi) in
        // Only support root directory (ino == 1)
        let TIMEOUT = 10_000_000.0;

        guard ino == 1 else {
            fuse_reply_err(req, ENOENT)
            return
        }

        // Hardcoded directory entries
        let entries: [(name: String, ino: UInt64, mode: mode_t)] = [
            (".", 1, S_IFDIR),
            ("..", 1, S_IFDIR),
            ("file1.txt", 2, S_IFREG)
        ]

        // Helper to fill a single direntry
        func fillDirEntry(buf: UnsafeMutableRawPointer?, bufsize: size_t, name: String, ino: UInt64, mode: mode_t, off: off_t) -> size_t {
            var entryParam = fuse_entry_param()
            memset(&entryParam, 0, MemoryLayout<fuse_entry_param>.size)

            if (name == "." || name == "..") {
                entryParam.attr.st_ino = ino_t(ino)
                entryParam.attr.st_mode = mode | (mode == S_IFDIR ? 0o755 : 0o644)
            } else {
                // todo lookup_node=  
                entryParam.ino = fuse_ino_t(ino)
                entryParam.attr.st_ino = ino_t(ino)
                entryParam.attr.st_mode = mode | (mode == S_IFDIR ? 0o755 : 0o644)
                entryParam.attr.st_nlink = mode == S_IFDIR ? 2 : 1
                entryParam.attr.st_size = mode == S_IFDIR ? 0 : 5004  // Dummy file size
                entryParam.attr_timeout = TIMEOUT
                entryParam.entry_timeout = TIMEOUT    
            }
            
            // let cName = strdup(name)
            // defer { free(cName) }
            return name.withCString { cName in
                fuse_add_direntry_plus(req, buf, bufsize, cName, &entryParam, off)
            } 
        }

        // Allocate buffer
        let buf = UnsafeMutablePointer<Int8>.allocate(capacity: Int(size))
        // let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<Int8>.alignment)
        defer { buf.deallocate() }

        var bufused: size_t = 0
        var idx = Int(off)

        // Guard against out-of-bounds index
        guard idx < entries.count else {
            // No more entries to return
            fuse_reply_buf(req, buf, 0)
            return
        }

        while idx < entries.count {
            let entry = entries[idx]
            let remaining = size - bufused
            
            // First check if there's any space left before calculating entry size
            if remaining == 0 {
                break
            }
            
            // Calculate the size this entry would take
            let entrySize = fillDirEntry(
                buf: buf.advanced(by: Int(bufused)),
                bufsize: remaining,
                name: entry.name,
                ino: entry.ino,
                mode: entry.mode,
                off: off_t(idx + 1)
            )
            
            // Check if the entry actually fits in the remaining buffer
            if entrySize > remaining {
                // todo do_forget() because I got ino
                // Entry doesn't fit, stop here
                break
            }
            
            // Entry fits, update buffer position and continue
            bufused += entrySize
            idx += 1
        }

        // print("Debug: Buffer used \(bufused), size \(size), entries \(entries.count), idx \(idx)")
        // let debugData = Data(bytes: buf, count: bufused)
        // let hexDump = debugData.map { String(format: "%02x", $0) }.joined(separator: " ")
        // print("Debug: Buffer used \(bufused) bytes, hex dump: \(hexDump)")
        fuse_reply_buf(req, buf, bufused)
    }
    // operations.readdirplus = { (req, ino, size, off, fi) in
    //     print("readdirplus: ino=\(ino), size=\(size), off=\(off)")

    //     // Define hardcoded directory entries
    //     let entries: [(name: String, ino: UInt64, type: UInt32)] = [
    //         (".", ino, S_IFDIR),
    //         ("..", 1, S_IFDIR),
    //         ("file1.txt", 2, S_IFREG),
    //     ]

    //     // Create a buffer for the directory entries
    //     let bufSize = size
    //     let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: Int(bufSize))
    //     defer { buffer.deallocate() }

    //     var bufPos: size_t = 0
    //     var nextOff = off

    //     // Add entries to the buffer
    //     for (idx, entry) in entries.enumerated() {
    //         if idx < Int(off) {
    //             continue
    //         }

    //         // Skip if we've already filled the buffer
    //         if bufPos >= bufSize {
    //             break
    //         }

    //         // Prepare the entry parameters
    //         var entryParam = fuse_entry_param()
    //         entryParam.ino = fuse_ino_t(entry.ino)
    //         entryParam.attr.st_ino = ino_t(entry.ino)
    //         entryParam.attr.st_mode = entry.type == S_IFDIR ? S_IFDIR | 0o755 : S_IFREG | 0o644
    //         entryParam.attr.st_nlink = entry.type == S_IFDIR ? 2 : 1
    //         entryParam.attr.st_size = entry.type == S_IFDIR ? 0 : 1024  // Dummy file size
    //         entryParam.attr_timeout = 1.0
    //         entryParam.entry_timeout = 1.0

    //         // Convert name to C string
    //         let cName = strdup(entry.name)
    //         defer { free(cName) }

    //         // Calculate how much space this entry will take
    //         let entrySize = fuse_add_direntry_plus(
    //             req,
    //             buffer.advanced(by: Int(bufPos)),
    //             bufSize - bufPos,
    //             cName,
    //             &entryParam,
    //             off_t(0)
    //         )

    //         // If it doesn't fit, stop here
    //         if bufPos + entrySize > bufSize {
    //             break
    //         }

    //         nextOff = off_t(idx + 1)
    //     }

    //     // Reply with the filled buffer
    //     fuse_reply_buf(req, buffer, bufPos)
    // }
    // operations.readdir = ll_readdir
    // operations.forget = ll_forget
    // operations.open = ll_open
    // operations.read = ll_read

    // Mount point
    let mountPoint = "/tmp/fuse-mount3"

    let fs = FileSystem()
    context.rootNode = try fs.createRootNode(manifestPath: "/workspaces/FSKitSample/fuse-state.json")

    // Create mount point if needed
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: mountPoint) {
        do {
            try fileManager.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
            print("Created mount point at \(mountPoint)")
        } catch {
            print("Error creating mount point: \(error)")
            return
        }
    }

    // Prepare arguments
    let args = [
        CommandLine.arguments[0],
        // "-f",  // Run in foreground
        "-d",  // Debug output
        // mountPoint,
    ]

    // Convert to C-style args
    var cArgs: [UnsafeMutablePointer<Int8>?] = args.map { strdup($0) }
    cArgs.append(nil)  // NULL-terminate

    var args_struct = fuse_args(argc: Int32(args.count), argv: &cArgs, allocated: 0)

    // Create session
    let session = fuse_session_new(
        &args_struct, &operations, MemoryLayout<fuse_lowlevel_ops>.size, nil)
    guard session != nil else {
        throw NSError(
            domain: "FUSEError", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to create FUSE session"])
    }
    defer {
        fuse_session_destroy(session)
    }

    guard fuse_set_signal_handlers(session) == 0 else {
        throw NSError(
            domain: "FUSEError", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Failed to set signal handlers"])
    }
    defer {
        fuse_remove_signal_handlers(session)
    }

    // Mount filesystem
    guard fuse_session_mount(session, mountPoint) == 0 else {
        throw NSError(
            domain: "FUSEError", code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Failed to mount FUSE filesystem"])
    }
    defer {
        fuse_session_unmount(session)
    }

    let foreground: Int32 = 1  //If foreground is 0, fuse_daemonize() will detach from the controlling terminal and run in the background as a system daemon. Otherwise, the process will continue to run in the foreground.
    let multithreaded = false
    let max_threads: UInt32 = 4
    let clone_fd: UInt32 = 1  //whether to use separate device fds for each thread (may increase performance)
    fuse_daemonize(foreground)
    var ret: Int32 = 0
    if multithreaded {
        let config = fuse_loop_cfg_create()
        fuse_loop_cfg_set_clone_fd(config, clone_fd)
        fuse_loop_cfg_set_max_threads(config, max_threads)
        // fuse_loop_cfg_set_idle_threads
        ret = fuse_session_loop_mt_32(session, config)
        fuse_loop_cfg_destroy(config)

    } else {
        ret = fuse_session_loop(session)
    }

    for arg in cArgs where arg != nil {
        free(arg)
    }

    // print("FUSE filesystem exited with status: \(result)")
}

// Start the filesystem
try main()
