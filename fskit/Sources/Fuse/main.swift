import FSKit
import Foundation
import clibfuse
import common



class Context {
    var fileSystem: FileSystem!
}

let context = Context()
let TIMEOUT = DBL_MAX

extension FSItem.Attributes {
    func toStat() -> stat {
        var st = stat()
        memset(&st, 0, MemoryLayout<stat>.size)
        //todo all stats
        st.st_ino = ino_t(self.fileID.rawValue)
        st.st_mode = self.mode
        st.st_nlink = __nlink_t(self.linkCount)
        st.st_size = Int(self.size)
        return st
    }
}

class PlusPacker: FSDirectoryEntryPacker {
    private var data: Data
    private let allBufSize: Int
    private var bufused: size_t = 0
    private let req: fuse_req_t?

    init(req: fuse_req_t?, bufSize: Int) {
        allBufSize = bufSize
        self.req = req
        data = Data(capacity: Int(bufSize))  //todo change to data
    }

    func packEntry(
        name filename: FSFileName, itemType: FSItem.ItemType, itemID: FSItem.Identifier,
        nextCookie: FSDirectoryCookie, attributes: FSItem.Attributes?
    ) -> Bool {
        // todo https://github.com/libfuse/libfuse/blob/b773020464641d3e9cec5ad5fa35e7153e54e118/lib/fuse.c#L3698
        // print ("packEntry: \(filename.string ?? "")")
        let remaining = allBufSize - bufused
        // check remaining?
        guard let name = filename.string else {
            // todo warn
            return true
        }
        let attr = attributes!
        // if name == "." || name == ".." {
        //     //todo should I send all attrs?
        //     attr = FSItem.Attributes()
        //     attr.fileID = itemID
        //     attr.mode = UInt32(clibfuse.S_IFDIR | 0o755)
        //     attr.linkCount = 2
        //     attr.size = 0
        // } else {
            // attr = attributes!
        // }

        var entry = fuse_entry_param(
            ino: itemID.toFuseIno(),
            generation: 0,
            attr: attr.toStat(),
            attr_timeout: TIMEOUT,
            entry_timeout: TIMEOUT
        )

        let entrySize = name.withCString { cName in
            data.withUnsafeMutableBytes { allBuf in
                fuse_add_direntry_plus(
                    req, allBuf.baseAddress!.advanced(by: bufused), remaining, cName, &entry,
                    Int(nextCookie.rawValue))
            }
        }
        if entrySize > remaining {
            return false
        }

        bufused += entrySize
        return true
    }
    func getBuf() -> (data: Data, used: size_t) {
        return (data: data, used: bufused)
    }
}

extension fuse_ino_t {
    func toId() -> FSItem.Identifier {
        return FSItem.Identifier(rawValue: UInt64(self))!
    }
}
extension FSItem.Identifier {
    func toFuseIno() -> fuse_ino_t {
        return fuse_ino_t(self.rawValue)
    }
}

class SendableAnything<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}
func reply_err(_ req: fuse_req_t?, _ error: Error) {
    if let err = error as? POSIXErrorCode {
        fuse_reply_err(req, err.rawValue)  //todo err
    } else {
        fuse_reply_err(req, EIO)  //todo err
    }
}

let lookupGetAttr = FSItem.GetAttributesRequest([.fileID, .mode, .linkCount, .size])  //todo

@MainActor
func main() throws {
    print("Starting low-level FUSE filesystem...")

    let pid = getpid()
    print("Process ID: \(pid)")
    // let llfs = LLFS()
    // Initialize operations structure
    var operations = fuse_lowlevel_ops()
    // operations.init = ll_init
    // operations.destroy =
    // operations.setattr =
    // operations.write =
    // operations.open =  ?
    // operations.flush =  ?
    // operations.release =  ?
    operations.opendir = { (req, ino, fi) in
        fi!.pointee.cache_readdir = 1
        fi!.pointee.keep_cache = 1
        fuse_reply_open(req, fi)
    }
    operations.lookup = { (req, parent, name) in
        let req = SendableAnything(req)
        let fs = context.fileSystem!

        let name = String(cString: name!)

        Task.detached {

            // print("lookup: parent=\(parent), name=\(name)")

            do {
                // todo negative lookpu entry (ino=0)
                let item = try await fs.lookupItem(
                    FSFileName(string: name), inDirectory: parent.toId())

                let stat = try await fs.getAttributes(lookupGetAttr, of: item.0)

                var entry = fuse_entry_param(
                    ino: item.0.toFuseIno(),
                    generation: 0,
                    attr: stat.toStat(),
                    attr_timeout: TIMEOUT,
                    entry_timeout: TIMEOUT
                )

                fuse_reply_entry(req.value, &entry)
            } catch {
                reply_err(req.value, error)  //todo err
            }
        }
    }
    operations.readlink = { (req, ino) in
        let req = SendableAnything(req)
        let fs = context.fileSystem!

        Task.detached {
            // print("readlink: ino=\(ino)")
            // Handle symbolic links
            do {
                let linkFileName = try await fs.readSymbolicLink(ino.toId())
                _ = linkFileName.string!.withCString { cString in
                    fuse_reply_readlink(req.value, cString)
                }
            } catch {
                reply_err(req.value, error)  //todo err
            }
        }
    }
    operations.getattr = { (req, ino, fi) in
        let req = SendableAnything(req)
        let fs = context.fileSystem!

        Task.detached {

            // print("getattr: ino=\(ino)")

            // Define a dummy stat structure
            let stat = try await fs.getAttributes(
                FSItem.GetAttributesRequest([
                    .uid, .modifyTime, .fileID, .type, .mode, .flags, .accessTime, .gid, .size,
                    .birthTime,
                ]), of: ino.toId())
            var st = stat.toStat()
            fuse_reply_attr(req.value, &st, TIMEOUT)
        }
    }
    operations.read = { (req, ino, size, offset, fi) in
        let req = SendableAnything(req)
        let fs = context.fileSystem!

        Task.detached {
            // print("read: ino=\(ino), size=\(size), offset=\(offset)")
            let buffer = DataBufferWrapper(capacity: Int(size))
            do {

                let written = try await fs.readData(
                    ino.toId(),
                    offset: offset,
                    length: size,
                    into: buffer,
                )

                _ = buffer.withUnsafeMutableBytes { rawBuffer in
                    fuse_reply_buf(req.value, rawBuffer.baseAddress!, written)
                }

                // // Use zero-copy reply when possible
                // if let mappedData = fileData.zeroCopyData {
                //     // Option 1: Zero-copy using fuse_buf with FUSE_BUF_IS_FD flag
                //     var buf = fuse_bufvec(count: 1, idx: 0, off: 0, buf: [
                //         fuse_buf(
                //             size: mappedData.size,
                //             flags: UInt32(FUSE_BUF_IS_FD | FUSE_BUF_FD_SEEK),
                //             fd: mappedData.fd,
                //             pos: mappedData.position
                //         )
                //     ])
                //     fuse_reply_data(req.value, &buf, UInt32(FUSE_BUF_COPY_FLAGS))
                // } else {
                //     // Option 2: Standard reply for when zero-copy isn't possible
                //     // Use the regular data buffer

                // }
            } catch {
                reply_err(req.value, error)
            }
        }
    }

    operations.readdirplus = { (req, ino, size, off, fi) in
        let req = SendableAnything(req)
        // DispatchQueue.global().async {

        let fs = context.fileSystem!

        Task.detached {
            let packer = PlusPacker(req: req.value, bufSize: size)

            // print("readdirplus: starting enumeration")
            do {
                // sleep(10)
                // try await Task.sleep(for: .seconds(1))
                let _ = try await fs.enumerateDirectory(
                    directory: ino.toId(),
                    startingAt: FSDirectoryCookie(UInt64(off)),
                    verifier: FSDirectoryVerifier(0),
                    attributes: lookupGetAttr,
                    packer: packer
                )
                let buf = packer.getBuf()
                // readdirplus: starting enumeration
                // readdirplus: replied with 656 bytes
                // readdirplus: starting enumeration
                // readdirplus: replied with 0 bytes
                // print("readdirplus: replied with \(buf.used) bytes") // many times returns 0 bytes
                _ = buf.data.withUnsafeBytes { rawBuffer in
                    fuse_reply_buf(req.value, rawBuffer.baseAddress, buf.used)
                }

            } catch {
                reply_err(req.value, error)
            }

        }
        // }
    }

    // Mount point
    var mountPoint: String? = nil
    var manifestPath: String? = nil
    var mutationsPath: String? = nil
    // path = "/Users/vadymh/github/fskit/FSKitSample/example/.yarn/fuse-state.json"
    var optionsIter = CommandLine.arguments[1...].makeIterator()
    while let option = optionsIter.next() {
        switch option {
        case "-m":
            manifestPath = optionsIter.next()
        case "-u":
            mutationsPath = optionsIter.next()
        default:
            mountPoint = option
        }
    }
    guard let mountPoint = mountPoint else {
        throw MyError.badMountParams
    }
    guard let manifestPath = manifestPath else {
        throw MyError.badMountParams
    }

    let fs = try FileSystem(
        manifestPath: manifestPath, mutationsPath: mutationsPath)
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
    Task.detached {
        while true {
            try await Task.sleep(for: .seconds(1))
            // Read process memory from /proc/self/statm and convert from pages to MB
            if let statm = try? String(contentsOfFile: "/proc/self/statm") {
                let components = statm.split(separator: " ")
                if components.count > 1, let rss = Double(components[1]) {
                    let pageSize = Double(getpagesize())
                    let memoryMB = (rss * pageSize) / (1024 * 1024)
                    print("used memory: \(String(format: "%.2f", memoryMB)) MB")
                }
            }
        }
    }
    print("CommandLine.arguments: \(CommandLine.arguments)")
    // Prepare arguments
    let args =
        [
            CommandLine.arguments[0],
            // "-f",  // Run in foreground
            // "-d",  // Debug output
            "-o",
            "default_permissions,auto_unmount",  //io_uring
            // "-o",
            // mountPoint,
        ] + (mutationsPath == nil ? ["-o", "ro"] : [])

    // Convert to C-style args
    var cArgs: [UnsafeMutablePointer<Int8>?] = args.map { strdup($0) }
    cArgs.append(nil)  // NULL-terminate

    var args_struct = fuse_args(argc: Int32(args.count), argv: &cArgs, allocated: 0)

    // Create session
    let session = fuse_session_new_fn(
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
    // if multithreaded {
    //     let config = fuse_loop_cfg_create()
    //     fuse_loop_cfg_set_clone_fd(config, clone_fd)
    //     fuse_loop_cfg_set_max_threads(config, max_threads)
    //     // fuse_loop_cfg_set_idle_threads
    //     ret = fuse_session_loop_mt_32(session, config)
    //     fuse_loop_cfg_destroy(config)

    // } else {
    ret = fuse_session_loop(session)
    // }

    for arg in cArgs where arg != nil {
        free(arg)
    }
    
    exit(ret)

    // print("FUSE filesystem exited with status: \(result)")
}

// Start the filesystem
try main()
