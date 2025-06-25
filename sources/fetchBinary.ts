import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import * as crypto from 'crypto';
import * as https from 'https';
import { tmpdir } from 'os';
import { pipeline } from 'stream/promises';
import { mkdir, mkdtemp } from 'fs/promises';
import * as tar from 'tar';
import { Transform } from 'stream';

//@ts-ignore-error
import VERSIONS_DATA from './versions.json';

import { VersionsData, PackageInfo } from './types';

/**
 * Creates a stream that downloads a file from a URL
 */
function createDownloadStream(url: string) {
  return new Promise<NodeJS.ReadableStream>((resolve, reject) => {
    const req = https.get(url, (res) => {
      if (res.statusCode !== 200) {
        reject(
          new Error(
            `Failed to download: ${res.statusCode} ${res.statusMessage}`,
          ),
        );
        return;
      }
      resolve(res);
    });
    req.on('error', (err) => {
      reject(err);
    });
    req.end();
  });
}

/**
 * Creates a transform stream that checks the hash of the data passing through it
 */
function createHashCheckStream(expectedIntegrity: string) {
  const [algorithm, expectedHashBase64] = expectedIntegrity.split('-');
  if (!algorithm || !expectedHashBase64) {
    throw new Error(`Invalid integrity format: ${expectedIntegrity}`);
  }

  // Remove any URL-safe base64 adjustments and convert to Buffer
  const expectedHash = Buffer.from(expectedHashBase64, 'base64');
  const hash = crypto.createHash(algorithm);

  // Create a transform stream that hashes data as it passes through
  const transformStream = new Transform({
    transform(
      chunk: Buffer,
      encoding: string,
      callback: (error?: Error | null, data?: any) => void,
    ) {
      hash.update(chunk);
      callback(null, chunk);
    },
    flush(callback: (error?: Error | null, data?: any) => void) {
      const digest = hash.digest();
      if (Buffer.compare(digest, expectedHash) !== 0) {
        callback(new Error(`Checksum mismatch`));
        return;
      }
      callback();
    },
  });

  return transformStream;
}



/**
 * Gets the appropriate binary package info for current platform
 */
function getPackageInfoForPlatform(
  versionsData: VersionsData,
): PackageInfo | null {
  // Get current platform details
  const platform = os.platform();
  const arch = os.arch();

  // Map Node.js platform to package platform
  let packageOS: string;
  switch (platform) {
    case 'darwin':
      packageOS = 'darwin';
      break;
    case 'linux':
      packageOS = 'linux';
      break;
    case 'win32':
      packageOS = 'win32';
      break;
    default:
      console.error(`Unsupported platform: ${platform}`);
      return null;
  }

  // Find matching package in the versions data
  const matchingPackage = versionsData.packages.find(
    (pkg: PackageInfo) => pkg.os === packageOS && pkg.arch === arch,
  );

  if (!matchingPackage) {
    console.error(`No matching binary package found for ${packageOS}-${arch}`);
    return null;
  }

  return matchingPackage;
}

async function verifyIntegrityOrThrow(
  filePath: string,
  expectedIntegrity: string,
) {
  const [algorithm, expectedHashBase64] = expectedIntegrity.split('-');
  if (!algorithm || !expectedHashBase64) {
    throw new Error(`Invalid integrity format: ${expectedIntegrity}`);
  }

  // Remove any URL-safe base64 adjustments and convert to Buffer
  const expectedHash = Buffer.from(expectedHashBase64, 'base64');

  const hash = crypto.createHash(algorithm);
  const stream = fs.createReadStream(filePath);
  await pipeline(stream, hash);

  if (Buffer.compare(hash.digest(), expectedHash) !== 0) {
    throw new Error(`Checksum mismatch for ${filePath}`);
  }
}

function downloadFileStream(url: string, dest: string) {
  const tmpPath = path.join(os.tmpdir(), crypto.randomUUID());
  return new Promise<void>((resolve, reject) => {
    const file = fs.createWriteStream(tmpPath);
    const req = https.get(url, (res) => {
      res.pipe(file);
      file.on('finish', () => {
        file.close();
        fs.rename(tmpPath, dest, (err) => {
          if (err) {
            reject(err);
          } else {
            resolve();
          }
        });
      });
    });
    req.on('error', (err) => {
      reject(err);
    });
    req.end();
  });
}

async function downloadAndExtractBinary(
  tarballUrl: string,
  integrity: string,
) {
  // Create a temporary directory for the download
  const tempDir = await mkdtemp(path.join(tmpdir(), 'fskit-binary-'));
  await pipeline(
    await createDownloadStream(tarballUrl),
    createHashCheckStream(integrity),
    tar.extract({
      cwd: tempDir,
      strict: true,
    }),
  );
  return tempDir;
}

/**
 * Fetches the appropriate binary for the current platform
 * @param destinationPath Optional path where to place the binary, defaults to current directory
 * @returns Promise<string> Path to the downloaded binary
 */
export async function fetchBinary(destinationPath?: string): Promise<string> {
  try {
    // Load versions data

    // Get package info for current platform
    const packageInfo = getPackageInfoForPlatform(VERSIONS_DATA);
    if (!packageInfo) {
      throw new Error('No compatible binary package found for your platform');
    }

    console.log(`Found matching binary: ${packageInfo.tarballUrl}`);

    // Download and extract the binary
    const binaryPath = await downloadAndExtractBinary(
      packageInfo.tarballUrl,
      packageInfo.integrity,
    );

    // Move to destination if specified
    if (destinationPath) {
      // Ensure destination directory exists
      const destDir = path.dirname(destinationPath);
      if (!fs.existsSync(destDir)) {
        await mkdir(destDir, { recursive: true });
      }

      // Copy binary to destination
      const binaryName = path.basename(binaryPath);
      const finalPath = path.join(destinationPath, binaryName);

      fs.copyFileSync(binaryPath, finalPath);
      fs.chmodSync(finalPath, '755');

      // Clean up temporary files
      fs.rmSync(path.dirname(path.dirname(binaryPath)), {
        recursive: true,
        force: true,
      });

      return finalPath;
    }

    return binaryPath;
  } catch (error) {
    console.error('Failed to fetch binary:', error);
    throw error;
  }
}
