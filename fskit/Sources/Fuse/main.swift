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
    var fileSystem: FileSystem!
}

let context = Context()
let TIMEOUT = 10_000_000.0

class PlusPacker: FSDirectoryEntryPacker {
    private let allBuf: UnsafeMutablePointer<Int8>
    private let allBufSize: Int
    private var bufused: size_t = 0
    private let req: fuse_req_t?

    init(req: fuse_req_t?, bufSize: Int) {
        allBufSize = bufSize
        self.req = req
        allBuf = UnsafeMutablePointer<Int8>.allocate(capacity: Int(bufSize))
    }

    func packEntry(
        name filename: FSFileName, itemType: FSItem.ItemType, itemID: FSItem.Identifier,
        nextCookie: FSDirectoryCookie, attributes: FSItem.Attributes?
    ) -> Bool {
        // print ("packEntry: \(filename.string ?? "")")
        let remaining = allBufSize - bufused
        // check remaining?
        guard let name = filename.string else {
            // todo warn
            return true
        }

        var entryParam = fuse_entry_param()
        memset(&entryParam, 0, MemoryLayout<fuse_entry_param>.size)

        if name == "." || name == ".." {
            entryParam.attr.st_ino = ino_t(itemID.rawValue)
            entryParam.attr.st_mode = attributes!.mode
        } else {
            // todo lookup_node=
            entryParam.ino = fuse_ino_t(itemID.rawValue)
            entryParam.attr.st_ino = ino_t(itemID.rawValue)
            entryParam.attr.st_mode = attributes!.mode
            entryParam.attr.st_nlink = attributes!.linkCount
            entryParam.attr.st_size = Int(attributes!.size)  //todo all attr conv
            entryParam.attr_timeout = TIMEOUT
            entryParam.entry_timeout = TIMEOUT
        }

        let entrySize = name.withCString { cName in
            fuse_add_direntry_plus(
                req, allBuf.advanced(by: bufused), remaining, cName, &entryParam,
                Int(nextCookie.rawValue))
        }
        if entrySize > remaining {
            // todo do_forget() because I got ino
            // Entry doesn't fit, stop here
            return false
        }
        bufused += entrySize
        return true
    }
    func getBuf() -> (buf: UnsafeMutablePointer<Int8>, used: size_t) {
        return (buf: allBuf, used: bufused)
    }
    deinit {
        allBuf.deallocate()
    }
}

class SendableAnything<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}

@MainActor
func main() throws {
    print("Starting low-level FUSE filesystem...")

    let pid = getpid()
    print("Process ID: \(pid)")
    // let llfs = LLFS()
    // Initialize operations structure
    var operations = fuse_lowlevel_ops()
    // operations.init = ll_init
    // operations.destroy = ll_destroy
    // operations.lookup = ll_lookup
    operations.getattr = { (req, ino, fi) in
        let req = SendableAnything(req)
        Task.detached {

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
            fuse_reply_attr(req.value, &stbuf, 1.0)
        }
    }
    operations.readdirplus = { (req, ino, size, off, fi) in
        // Only support root directory (ino == 1)
        // print("readdirplus: ino=\(ino), size=\(size), off=\(off)")
        // guard ino == 1 else {
        //     fuse_reply_err(req, ENOENT)
        //     return
        // }
        let req = SendableAnything(req)
        // DispatchQueue.global().async {
    

        let fs = context.fileSystem!

        Task.detached {
            let packer = PlusPacker(req: req.value, bufSize: size)

            let attrReq = FSItem.GetAttributesRequest([.fileID, .mode, .linkCount, .size])  //todo
            print("readdirplus: starting enumeration")
            do {
                // sleep(10)
                // try await Task.sleep(for: .seconds(1))
                let _ = try await fs.enumerateDirectory(
                    directory: FSItem.Identifier(rawValue: ino)!, startingAt: FSDirectoryCookie(UInt64(off)),
                    verifier: FSDirectoryVerifier(0),
                    attributes: attrReq,
                    packer: packer
                )
                let buf = packer.getBuf()

               


                print("readdirplus: replied with \(buf.used) bytes")
                fuse_reply_buf(req.value, buf.buf, buf.used)
            } catch {
                print("readdirplus: error occurred")
                fuse_reply_err(req.value, EIO)  //todo err
            }

        }
        // }
    }

    // operations.readdir = ll_readdir
    // operations.forget = ll_forget
    // operations.open = ll_open
    // operations.read = ll_read

    // Mount point
    let mountPoint = CommandLine.arguments[3]

    let fs = try FileSystem(manifestPath: CommandLine.arguments[2], mutationsPath: CommandLine.arguments[3])
    context.fileSystem = fs
    

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
    print("CommandLine.arguments: \(CommandLine.arguments)")
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
    exit(ret)

    // print("FUSE filesystem exited with status: \(result)")
}

// Start the filesystem
try main()
