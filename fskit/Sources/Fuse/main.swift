import clibfuse
import Foundation
import Glibc  // Explicitly import Glibc to resolve ambiguities
import FSKit
import common

// MARK: - Constants and Globals

// Dummy directory entries that will be returned
let dummyEntries = [".", "..", "file1.txt", "file2.txt", "directory1", "directory2"]

// MARK: - FUSE Operations
// (@convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<stat>?, UnsafeMutablePointer<fuse_file_info>?) -> Int32)!
// Required: Get attributes of a file
let getattr: @convention(c) (UnsafePointer<Int8>?, UnsafeMutablePointer<stat>?, UnsafeMutablePointer<fuse_file_info>?) -> Int32 = { path, stbuf, file_info in
    guard let path = path, let stbuf = stbuf else {
        return -EINVAL
    }
    
    let pathStr = String(cString: path)
    memset(stbuf, 0, MemoryLayout<stat>.size)
    
    if pathStr == "/" {
        stbuf.pointee.st_mode = UInt32(clibfuse.S_IFDIR | 0o755)  // Specify module
        stbuf.pointee.st_nlink = 2
        return 0
    }
    
    // Extract filename from path
    let components = pathStr.split(separator: "/")
    if let filename = components.last {
        let filenameStr = String(filename)
        
        // Check if this is one of our dummy entries
        if dummyEntries.contains(filenameStr) {
            if filenameStr == "directory1" || filenameStr == "directory2" || filenameStr == "." || filenameStr == ".." {
                stbuf.pointee.st_mode = UInt32(clibfuse.S_IFDIR | 0o755)  // Specify module
                stbuf.pointee.st_nlink = 2
            } else {
                stbuf.pointee.st_mode = UInt32(clibfuse.S_IFREG | 0o644)  // Specify module
                stbuf.pointee.st_nlink = 1
                stbuf.pointee.st_size = 1024 // Dummy file size
            }
            return 0
        }
    }
    
    return -ENOENT
}

// UnsafePointer<CChar>?, UnsafeMutableRawPointer?, fuse_fill_dir_t?, off_t, UnsafeMutablePointer<fuse_file_info>?, fuse_readdir_flags) -> Int32
// The readdir operation instead of readdirplus (which may not be available in the struct)
let readdir: @convention(c) (
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?,
    fuse_fill_dir_t?,
    off_t,
    UnsafeMutablePointer<fuse_file_info>?,
    fuse_readdir_flags
) -> Int32 = { path, buf, filler, offset, fi, flags in
    guard let path = path, let buf = buf, let filler = filler else {
        return -EINVAL
    }
    
    let pathStr = String(cString: path)
    print("readdir called for path: \(pathStr)")
    
    for entry in dummyEntries {
        var st = stat()
        memset(&st, 0, MemoryLayout<stat>.size)
        
        // Set appropriate stat data based on entry type
        if entry == "directory1" || entry == "directory2" || entry == "." || entry == ".." {
            st.st_mode = UInt32(clibfuse.S_IFDIR | 0o755)  // Specify module
            st.st_nlink = 2
        } else {
            st.st_mode = UInt32(clibfuse.S_IFREG | 0o644)  // Specify module
            st.st_nlink = 1
            st.st_size = 1024 // Dummy file size
        }
        
        // Add current timestamps
        // let now = time(nil)
        // st.st_atim.tv_sec = now
        // st.st_mtim.tv_sec = now
        // st.st_ctim.tv_sec = now

        
        // Add entry to the buffer - using standard readdir pattern
        let entryCStr = strdup(entry)
        let result = filler(buf, entryCStr, &st, 0, FUSE_FILL_DIR_PLUS) //todo 0 mean no seek
        free(entryCStr)
        
        if result != 0 {
            break
        }
    }
    
    return 0
}

// MARK: - Main Function

@MainActor  // Mark as MainActor to fix isolation issue
func main() {
    print("Starting dummy FUSE filesystem...")
    
    // Initialize operations structure inside main function
    var operations = fuse_operations()
    operations.getattr = getattr
    operations.readdir = readdir  // Use readdir instead of readdirplus
    
    // Mount point - needs to exist
    let mountPoint = "/tmp/fuse-mount"
    
    // Create mount point if it doesn't exist
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
    
    // Prepare arguments for fuse_main
    let args = [
        CommandLine.arguments[0],
        "-f",                    // Run in foreground
        "-d",                    // Debug output
        mountPoint
    ]
    
    print("Mounting FUSE filesystem at \(mountPoint)")
    print("Dummy entries: \(dummyEntries.joined(separator: ", "))")
    
    // Convert args to C-style
    var cArgs: [UnsafeMutablePointer<Int8>?] = args.map { strdup($0) }
    cArgs.append(nil) // NULL-terminate
    
    // Start FUSE main loop
    let result = fuse_main_real(Int32(args.count), &cArgs, &operations, MemoryLayout<fuse_operations>.size, nil)
    
    // Clean up
    for arg in cArgs where arg != nil {
        free(arg)
    }
    
    print("FUSE filesystem exited with status: \(result)")
}

// Start the filesystem
main()