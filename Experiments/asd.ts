import fs from "fs";
import constants from "constants";
import path from "path";
import { Erofs } from "./erofs.ts";

const SIGNATURE = {
    CENTRAL_DIRECTORY: 0x02014b50,
    END_OF_CENTRAL_DIRECTORY: 0x06054b50,
};

const ZIP_UNIX = 3;

const noCommentCDSize = 22;

const SAFE_TIME = 456789000;

interface Entry {
    name: string;
    compressionMethod: number;
    size: number;
    os: number;
    isSymbolicLink: boolean;
    crc: number;
    compressedSize: number;
    externalAttributes: number;
    mtime: number;
    localHeaderOffset: number;
}


function readZipSync(fd: number, baseFs: typeof fs, fileSize: number): Array<Entry> {
    if (fileSize < noCommentCDSize)
        throw new Error(`Invalid ZIP file: EOCD not found`);

    let eocdOffset = -1;

    // fast read if no comment
    let eocdBuffer = Buffer.alloc(noCommentCDSize);
    baseFs.readSync(
        fd,
        eocdBuffer,
        0,
        noCommentCDSize,
        fileSize - noCommentCDSize,
    );

    if (eocdBuffer.readUInt32LE(0) === SIGNATURE.END_OF_CENTRAL_DIRECTORY) {
        eocdOffset = 0;
    } else {
        const bufferSize = Math.min(65557, fileSize);
        eocdBuffer = Buffer.alloc(bufferSize);

        // Read potential EOCD area
        baseFs.readSync(
            fd,
            eocdBuffer,
            0,
            bufferSize,
            Math.max(0, fileSize - bufferSize),
        );

        // Find EOCD signature
        for (let i = eocdBuffer.length - 4; i >= 0; i--) {
            if (eocdBuffer.readUInt32LE(i) === SIGNATURE.END_OF_CENTRAL_DIRECTORY) {
                eocdOffset = i;
                break;
            }
        }

        if (eocdOffset === -1) {
            throw new Error(`Not a zip archive`);
        }
    }

    const totalEntries = eocdBuffer.readUInt16LE(eocdOffset + 10);
    const centralDirSize = eocdBuffer.readUInt32LE(eocdOffset + 12);
    const centralDirOffset = eocdBuffer.readUInt32LE(eocdOffset + 16);
    const commentLength = eocdBuffer.readUInt16LE(eocdOffset + 20);

    // Optional check, fixes two tests: libzip/incons-archive-comment-longer.zip and go/comment-truncated.zip
    // https://github.com/golang/go/blob/f062d7b10b276c1b698819f492e4b4754e160ee3/src/archive/zip/reader_test.go#L573
    // Important to NOT skip last EOCDR. Both using last EOCDR or throwing error is fine, we throw
    if (eocdOffset + commentLength + noCommentCDSize > eocdBuffer.length)
        throw new Error(`Zip archive inconsistent`);

    if (totalEntries == 0xffff || centralDirSize == 0xffffffff || centralDirOffset == 0xffffffff)
        // strictly speaking, not correct, should find zip64 signatures. But chances are 0 for false positives.
        throw new Error(`Zip 64 is not supported`);

    if (centralDirSize > fileSize)
        throw new Error(`Zip archive inconsistent`);

    if (totalEntries > centralDirSize / 46)
        throw new Error(`Zip archive inconsistent`);

    // Read central directory
    const cdBuffer = Buffer.alloc(centralDirSize);
    if (baseFs.readSync(fd, cdBuffer, 0, cdBuffer.length, centralDirOffset) !== cdBuffer.length)
        throw new Error(`Zip archive inconsistent`);

    const entries: Array<Entry> = [];

    let offset = 0;
    let index = 0;
    let sumCompressedSize = 0;

    while (index < totalEntries) {
        if (offset + 46 > cdBuffer.length)
            throw new Error(`Zip archive inconsistent`);

        if (cdBuffer.readUInt32LE(offset) !== SIGNATURE.CENTRAL_DIRECTORY)
            throw new Error(`Zip archive inconsistent`);

        const versionMadeBy = cdBuffer.readUInt16LE(offset + 4);
        const os = versionMadeBy >>> 8;

        const flags = cdBuffer.readUInt16LE(offset + 8);
        if ((flags & 0x0001) !== 0)
            throw new Error(`Encrypted zip files are not supported`);

        // we don't care about data descriptor because we dont read size and crc from local file header
        // const hasDataDescriptor = (flags & 0x8) !== 0;
        const compressionMethod = cdBuffer.readUInt16LE(offset + 10);
        const crc = cdBuffer.readUInt32LE(offset + 16);
        const nameLength = cdBuffer.readUInt16LE(offset + 28);
        const extraLength = cdBuffer.readUInt16LE(offset + 30);
        const commentLength = cdBuffer.readUInt16LE(offset + 32);
        const localHeaderOffset = cdBuffer.readUInt32LE(offset + 42);

        const name = cdBuffer.toString(`utf8`, offset + 46, offset + 46 + nameLength).replaceAll(`\0`, ` `);
        if (name.includes(`\0`))
            throw new Error(`Invalid ZIP file`);

        const compressedSize = cdBuffer.readUInt32LE(offset + 20);
        const externalAttributes = cdBuffer.readUInt32LE(offset + 38);

        entries.push({
            name,
            os,
            mtime: SAFE_TIME, //we dont care,
            crc,
            compressionMethod,
            isSymbolicLink: os === ZIP_UNIX && ((externalAttributes >>> 16) & constants.S_IFMT) === constants.S_IFLNK,
            size: cdBuffer.readUInt32LE(offset + 24),
            compressedSize,
            externalAttributes,
            localHeaderOffset,
        });

        sumCompressedSize += compressedSize;

        index += 1;
        offset += 46 + nameLength + extraLength + commentLength;
    }

    // fast check for archive bombs
    if (sumCompressedSize > fileSize)
        throw new Error(`Zip archive inconsistent`);

    if (offset !== cdBuffer.length)
        throw new Error(`Zip archive inconsistent`);

    return entries;
}

/**
 * Recursively finds all ZIP files in a directory
 */
function findZipFiles(directory: string): string[] {
    const zipFiles: string[] = [];

    try {
        const entries = fs.readdirSync(directory, { withFileTypes: true });

        for (const entry of entries) {
            const fullPath = path.join(directory, entry.name);

            if (entry.isDirectory()) {
                // Recursively search subdirectories
                zipFiles.push(...findZipFiles(fullPath));
            } else if (entry.isFile() && entry.name.toLowerCase().endsWith('.zip')) {
                zipFiles.push(fullPath);
            }
        }
    } catch (error) {
        console.error(`Error reading directory ${directory}:`, error);
    }

    return zipFiles;
}

const erofs = new Erofs(path.join(process.cwd(), 'erofs.img'));
const uid = process.getuid!();
const gid = process.getgid!();
/**
 * Reads all zip files in the specified directory and logs the time elapsed
 */
function readAllZipsInDirectory(directory: string): void {
    console.log(`Searching for ZIP files in ${directory}...`);

    const zipFiles = findZipFiles(directory);


    erofs.addNode('directory', 0o755, uid, gid, undefined) //root

    const buffer = erofs.getDirentriesBuffer(zipFiles.map(file => {
        const node = erofs.addNode('directory', 0o755, uid, gid, undefined)

        return {
            name: path.basename(file),
            nid: node.inodeNumber,
            type: 'directory'
        }
    }))

    //todo write

    console.log(`Found ${zipFiles.length} ZIP files.`);

    let totalEntries = 0;
    let processedFiles = 0;

    const startTime = process.hrtime();

    for (const zipFile of zipFiles) {
        try {
            const stats = fs.statSync(zipFile);
            const fd = fs.openSync(zipFile, 'r');

            try {
                const entries = readZipSync(fd, fs, stats.size);
                for (const entry of entries) {
                    const node = erofs.addNode('file', 0o644, uid, gid, undefined)
                }
                totalEntries += entries.length;
                processedFiles++;

                // console.log(`Read ${zipFile}: ${entries.length} entries`);
            } finally {
                fs.closeSync(fd);
            }
        } catch (error) {
            console.error(`Error processing ${zipFile}:`, error);
        }
    }

    const elapsedTime = process.hrtime(startTime);
    const elapsedMs = (elapsedTime[0] * 1000 + elapsedTime[1] / 1000000).toFixed(2);
    erofs.finalize()
    console.log(`---------------------------------`);
    console.log(`Processing complete:`);
    console.log(`- Time elapsed: ${elapsedMs} ms`);
    console.log(`- Files processed: ${processedFiles} of ${zipFiles.length}`);
    console.log(`- Total entries: ${totalEntries}`);
}

// Main execution
const yarnCachePath = path.join(process.env.HOME!, '.yarn/berry/cache');

try {
    if (fs.existsSync(yarnCachePath)) {
        readAllZipsInDirectory(yarnCachePath);
    } else {
        console.log(`Directory not found: ${yarnCachePath}`);
        console.log(`Trying to search in node_modules for ZIP files...`);
        readAllZipsInDirectory(path.join(process.cwd(), 'node_modules'));
    }
} catch (error) {
    console.error('Error:', error);
}

