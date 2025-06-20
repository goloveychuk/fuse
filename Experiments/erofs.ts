import * as fs from 'fs';

export class Erofs {
    private fd: number; // File descriptor for the output file
    private buffer: Buffer; // 1MB buffer
    private _bufferOffset: number;
    private fileSize: number = 0; // Current file size
    
    constructor(filePath: string) {
        // Open the file for writing, create it if it doesn't exist, truncate if it does
        this.fd = fs.openSync(filePath, 'w+');
        this.buffer = Buffer.alloc(1024 * 1024, 0); // 1MB buffer
        this.metablockData = {
            totalFiles: 0
        };
        this.nextInodeNumber = 1; // Root inode is typically 1
        this.nextBlockAddr = 1; // Start after superblock
        
        // Reserve space for the superblock (1024 bytes)
        this._bufferOffset = this.EROFS_SUPER_OFFSET
        
        // We'll initialize the root directory when needed (lazy initialization)
    }

    private metablockData: {
        totalFiles: number;
    };

    // Counters for allocation
    private nextInodeNumber: number;
    private nextBlockAddr: number;

    // EROFS inode format flags
    private readonly EROFS_INODE_LAYOUT_COMPACT = 0; // compact inode layout (32 bytes)
    // private readonly EROFS_INODE_LAYOUT_EXTENDED = 1; // extended inode layout (64 bytes)
    private readonly EROFS_INODE_FLAT_PLAIN = 0; // inode data layout - flat plain
    private readonly EROFS_INODE_FLAT_INLINE = 2; // inode data layout - flat inline
    // private readonly EROFS_INODE_CHUNK_BASED = 4; // inode data layout - chunk based

    // File mode constants
    private readonly S_IFDIR = 0x4000;  // Directory
    private readonly S_IFREG = 0x8000;  // Regular file
    private readonly S_IFLNK = 0xA000;  // Symbolic link
    // private readonly S_IFBLK = 0x6000;  // Block device
    // private readonly S_IFCHR = 0x2000;  // Character device

    // File type values for directory entries
    // private readonly DT_UNKNOWN = 0;
    private readonly DT_REG = 1;
    private readonly DT_DIR = 2;
    // private readonly DT_CHR = 3;
    // private readonly DT_BLK = 4;
    // private readonly DT_FIFO = 5;
    // private readonly DT_SOCK = 6;
    private readonly DT_LNK = 7;

    private readonly BLOCK_SIZE = 4096; // 512 is minimum

    // EROFS superblock constants
    private readonly EROFS_SUPER_MAGIC = 0xE0F5E1E2;
    private readonly EROFS_SUPER_OFFSET = 1024; // Superblock starts at the beginning of the file TODO not really

    /**
     * Ensures there's enough space in the buffer for the requested bytes
     * @param size Number of bytes to reserve
     */
    private reserveBytes(size: number): number {
        if (this._bufferOffset + size > this.buffer.length) {
            this.flushBuffer();
        }
        const offset = this._bufferOffset;
        this._bufferOffset += size;
        return offset;
    }



    /**
     * Flushes the buffer to disk
     */
    private flushBuffer(): void {
        if (this._bufferOffset > 0) {
            fs.writeSync(this.fd, this.buffer, 0, this._bufferOffset);
            this._bufferOffset = 0; // Reset buffer offset
        }
    }

    /**
     * Writes the EROFS superblock to the beginning of the file
     */
    private getSuperblockBuffer() {
        // Make sure root directory is initialized
        
        // Create a buffer for the superblock (128 bytes)
        const superblockBuffer = Buffer.alloc(128);
        
        // magic (4 bytes): Magic signature 0xE0F5E1E2
        superblockBuffer.writeUInt32LE(this.EROFS_SUPER_MAGIC, 0);
        
        // checksum (4 bytes): Superblock checksum - we'll set to 0 for now
        superblockBuffer.writeUInt32LE(0, 4);
        
        // feature_compat (4 bytes): Compatible feature flags
        superblockBuffer.writeUInt32LE(0, 8);
        
        // blkszbits (1 byte): Block size = 2^blkszbits (minimum 9 for 512 byte blocks)
        superblockBuffer.writeUInt8(Math.log2(this.BLOCK_SIZE), 12);
        
        // sb_extslots (1 byte): Extended superblock slots
        superblockBuffer.writeUInt8(0, 13);
        
        // root_nid (2 bytes): Node ID of root directory
        superblockBuffer.writeUInt16LE(1, 14); // We always use inode 1 for root
        
        // inos (8 bytes): Total valid inode count
        const inoBuffer = Buffer.alloc(8);
        inoBuffer.writeBigUInt64LE(BigInt(this.nextInodeNumber - 1), 0);
        inoBuffer.copy(superblockBuffer, 16);
        
        // build_time (8 bytes): When filesystem was created (seconds since epoch)
        const timeBuffer = Buffer.alloc(8);
        const now = Math.floor(Date.now() / 1000);
        timeBuffer.writeBigUInt64LE(BigInt(now), 0);
        timeBuffer.copy(superblockBuffer, 24);
        
        // build_time_ns (4 bytes): Nanosecond component of timestamp
        superblockBuffer.writeUInt32LE(0, 32);
        
        // blocks (4 bytes): Total block count
        superblockBuffer.writeUInt32LE(this.nextBlockAddr, 36);
        
        // meta_blkaddr (4 bytes): Start block address of metadata area
        superblockBuffer.writeUInt32LE(0, 40); // We start metadata at block 0
        
        // xattr_blkaddr (4 bytes): Start block address of shared extended attribute area
        superblockBuffer.writeUInt32LE(0, 44); // No shared xattr support yet
        
        // uuid (16 bytes): 128-bit UUID for volume
        for (let i = 0; i < 16; i++) {
            superblockBuffer.writeUInt8(i, 48 + i); // Simple placeholder UUID
        }
        
        // volume_name (16 bytes): Filesystem label
        const label = "EROFS-FSKIT";
        const labelBuffer = Buffer.from(label);
        labelBuffer.copy(superblockBuffer, 64, 0, Math.min(16, labelBuffer.length));
        
        // feature_incompat (4 bytes): Incompatible feature flags
        superblockBuffer.writeUInt32LE(0, 80);
        
        // Rest of the superblock is zeroed out (already done by Buffer.alloc)
        
        // Calculate a simple checksum over the superblock 
        let checksum = 0;
        // for (let i = 0; i < 128; i += 4) {
        //     if (i !== 4) { // Skip the checksum field itself
        //         checksum ^= superblockBuffer.readUInt32LE(i);
        //     }
        // }
        
        // Write the calculated checksum
        superblockBuffer.writeUInt32LE(checksum, 4);
        
        // Write the superblock to the beginning of the file
        return superblockBuffer;
    }

    /**
     * Writes a compact inode structure to the buffer
     * @param buffer Buffer to write to
     * @param offset Offset in the buffer to write the inode at
     * @param mode File mode (including type)
     * @param uid User ID
     * @param gid Group ID
     * @param nlink Number of hard links
     * @param size File size in bytes
     * @param rawBlkaddr Raw block address for data
     * @param ino Inode number
     * @param xattrCount Extended attribute count
     * @param dataLayout Data layout type (0: flat plain, 2: flat inline, 4: chunk based)
     */
    private writeInodeStructToBuffer(
        mode: number, 
        uid: number, 
        gid: number, 
        nlink: number, 
        size: number, 
        rawBlkaddr: number, 
        ino: number,
        xattrCount: number,
        dataLayout: number,
    ): void {
        const offset = this.reserveBytes(32);
        // i_format (2 bytes): Bits 0 = inode version (0 for compact), Bits 1-3 = data layout
        const iFormat = (this.EROFS_INODE_LAYOUT_COMPACT) | (dataLayout << 1);
        this.buffer.writeUInt16LE(iFormat, offset);
        
        // i_xattr_icount (2 bytes): Extended attribute count
        this.buffer.writeUInt16LE(xattrCount, offset + 2);
        
        // i_mode (2 bytes): File mode
        this.buffer.writeUInt16LE(mode, offset + 4);
        
        // i_nlink (2 bytes): Hard link count
        this.buffer.writeUInt16LE(nlink, offset + 6);
        
        // i_size (4 bytes): File size in bytes
        this.buffer.writeUInt32LE(size, offset + 8);
        
        // i_reserved (4 bytes): Reserved space
        this.buffer.writeUInt32LE(0, offset + 12);
        
        // i_u (4 bytes): Block address for data (or device number for device files)
        this.buffer.writeUInt32LE(rawBlkaddr, offset + 16);
        
        // i_ino (4 bytes): Inode incremental number
        this.buffer.writeUInt32LE(ino, offset + 20);
        
        // i_uid (2 bytes): Owner UID
        this.buffer.writeUInt16LE(uid, offset + 24);
        
        // i_gid (2 bytes): Owner GID
        this.buffer.writeUInt16LE(gid, offset + 26);
        
        // i_reserved2 (4 bytes): Reserved
        this.buffer.writeUInt32LE(0, offset + 28);
    }

    /**
     * Writes an inode to the file at the specified offset
     * @param offset Offset in the file to write the inode at
     * @param mode File mode (including type)
     * @param uid User ID
     * @param gid Group ID
     * @param nlink Number of hard links
     * @param size File size in bytes
     * @param rawBlkaddr Raw block address for data
     * @param ino Inode number
     * @param xattrCount Extended attribute count
     * @param dataLayout Data layout type (0: flat plain, 2: flat inline, 4: chunk based)
     */
    private writeInodeStruct(
        offset: number, 
        mode: number, 
        uid: number, 
        gid: number, 
        nlink: number, 
        size: number, 
        rawBlkaddr: number, 
        ino: number,
        xattrCount: number,
        dataLayout: number,
    ): void {
        
        this.writeInodeStructToBuffer(mode, uid, gid, nlink, size, rawBlkaddr, ino, xattrCount, dataLayout);
    }

    /**
     * Creates a buffer containing formatted directory entries
     * @param entries Array of directory entries to format
     * @returns A buffer containing the formatted directory entries
     */
    public getDirentriesBuffer(
        entries: Array<{name: string, nid: number, type: 'file' | 'directory' | 'symlink'}>
    ): {buffer: Buffer, blocksNeeded: number} {
        // Calculate how many blocks we need
        let totalNameBytes = 0;
        for (const entry of entries) {
            totalNameBytes += Buffer.from(entry.name).length;
        }
        
        // Each directory entry is 12 bytes
        const direntSize = 12;
        const totalDirentBytes = entries.length * direntSize;
        
        // Calculate total size including dirents and filenames
        const totalBytes = totalDirentBytes + totalNameBytes;
        
        // Calculate how many blocks we need
        const blocksNeeded = Math.ceil(totalBytes / this.BLOCK_SIZE);
        const totalSize = blocksNeeded * this.BLOCK_SIZE;
        
        // Create a buffer for all blocks
        const buffer = Buffer.alloc(totalSize);
        
        // First entry's nameoff field indicates the total number of entries
        if (entries.length > 0) {
            buffer.writeUInt16LE(entries.length, 8); // Write entry count at nameoff position of first entry
        }
        
        // Current position for writing filenames
        let nameOffset = totalDirentBytes;
        let currentBlock = 0;
        
        // Process each entry
        for (let i = 0; i < entries.length; i++) {
            const entry = entries[i];
            const direntOffset = i * direntSize;
            
            // Calculate which block this directory entry belongs to
            const entryBlock = Math.floor(direntOffset / this.BLOCK_SIZE);
            
            // If we've moved to a new block, reset the nameOffset to the beginning of the filename area in this block
            if (entryBlock > currentBlock) {
                // Move to the start of filename area in the new block
                nameOffset = (entryBlock + 1) * this.BLOCK_SIZE;
                currentBlock = entryBlock;
            }
            
            // Determine file type
            let fileType: number;
            switch (entry.type) {
                case 'file': fileType = this.DT_REG; break;
                case 'directory': fileType = this.DT_DIR; break;
                case 'symlink': fileType = this.DT_LNK; break;
            }
            
            // Write directory entry
            // nid (8 bytes)
            buffer.writeBigUInt64LE(BigInt(entry.nid), direntOffset);
            
            // nameoff (2 bytes) - offset to the filename, relative to the start of the current block
            const blockRelativeNameOffset = nameOffset % this.BLOCK_SIZE;
            buffer.writeUInt16LE(blockRelativeNameOffset, direntOffset + 8);
            
            // file_type (1 byte)
            buffer.writeUInt8(fileType, direntOffset + 10);
            
            // reserved (1 byte)
            buffer.writeUInt8(0, direntOffset + 11);
            
            // Write filename
            const nameBytes = Buffer.from(entry.name);
            nameBytes.copy(buffer, nameOffset);
            
            // Update nameOffset for next name
            nameOffset += nameBytes.length;
        }
        
        return {buffer, blocksNeeded};
    }

    /**
     * Add a new node (file or directory) to the filesystem
     * @param type Type of node ('file', 'directory', 'symlink', etc)
     * @param mode File permissions (e.g., 0o755)
     * @param uid User ID
     * @param gid Group ID
     * @param data File data (for regular files and symlinks)
     * @returns Object with inode number and other relevant information
     */
    public addNode(
        type: 'file' | 'directory' | 'symlink',
        mode: number = 0o644,
        uid: number = 0,
        gid: number = 0,
        data?: Buffer
    ) { 
        // Calculate the metadata block offset for this inode
        const inodeOffset = 1024 + (this.nextInodeNumber * 32); // First KB is reserved, then compact inodes
        
        // Determine file mode based on type
        let fileMode: number;
        let dataLayout = this.EROFS_INODE_FLAT_PLAIN;
        let size = 0;
        let dataBlkAddr = 0;
        
        switch (type) {
            case 'directory':
                fileMode = this.S_IFDIR | (mode & 0o777);
                // Directories need a data block to store entries
                dataBlkAddr = this.nextBlockAddr++; //todo
                break;
            case 'file':
                fileMode = this.S_IFREG | (mode & 0o777);
                if (data) {
                    size = data.length;
                    // For small files, we can use inline data
                    if (size <= 28) { // we have 28 bytes available in i_reserved + i_u + i_reserved2
                        dataLayout = this.EROFS_INODE_FLAT_INLINE;
                    } else {
                        // Allocate a data block
                        dataBlkAddr = this.nextBlockAddr;
                        this.nextBlockAddr += Math.ceil(data.length / this.BLOCK_SIZE); // Assuming 4KB blocks
                    }
                }
                break;
            case 'symlink':
                fileMode = this.S_IFLNK | (mode & 0o777);
                if (data) {
                    size = data.length;
                    if (size <= 28) {
                        dataLayout = this.EROFS_INODE_FLAT_INLINE;
                    } else {
                        dataBlkAddr = this.nextBlockAddr;
                        this.nextBlockAddr += Math.ceil(data.length / this.BLOCK_SIZE);
                    }
                }
                break;
            default:
                throw new Error(`Unsupported node type: ${type}`);
        }
        
        // Write inode structure
        const inodeNumber = this.nextInodeNumber++;
        this.writeInodeStruct(
            inodeOffset,
            fileMode,
            uid,
            gid,
            1, // nlink
            size,
            dataBlkAddr,
            inodeNumber,
            0, // xattrCount
            dataLayout
        );
        
        // If we have inline data, write it directly after the inode
        if (data && dataLayout === this.EROFS_INODE_FLAT_INLINE) {
            // For inline data, store it right after the inode
            // this.writeAtPosition(inodeOffset + 32, data.subarray(0, Math.min(data.length, 28))); //todo impl
        } 
        // If we have regular file data, write it at the allocated block address
        else if (data && dataBlkAddr > 0) {
            const dataOffset = dataBlkAddr * this.BLOCK_SIZE; // Assuming 4KB blocks
            
            // Write data in chunks if it's large
            const chunkSize = 1024 * 1024; // 1MB chunks
            for (let i = 0; i < data.length; i += chunkSize) {
                const end = Math.min(i + chunkSize, data.length);
                const chunk = data.subarray(i, end);
                // this.writeAtPosition(dataOffset + i, chunk); //todo impl
            }
        }
        
        this.metablockData.totalFiles++;
        
        return {
            inodeNumber,
            offset: inodeOffset,
            dataBlockAddr: dataBlkAddr,
            size,
            mode: fileMode
        };
    }

    /**
     * Finalizes the filesystem and closes the file
     */
    public finalize(): void {
        this.flushBuffer();
        // Write the superblock with final metadata
        const superblockBuffer = this.getSuperblockBuffer();
        fs.writeSync(this.fd, superblockBuffer, 0, superblockBuffer.length, this.EROFS_SUPER_OFFSET);
        
        // Make sure the buffer is flushed
        
        // Close the file
        fs.closeSync(this.fd);
    }

    /**
     * Gets statistics about the filesystem
     * @returns Object containing filesystem statistics
     */
    public getStats() {
        return {
            totalInodes: this.nextInodeNumber - 1,
            totalBlocks: this.nextBlockAddr,
            totalFiles: this.metablockData.totalFiles,
            sizeInBytes: this.nextBlockAddr * this.BLOCK_SIZE // Assuming 4KB blocks
        };
    }
}