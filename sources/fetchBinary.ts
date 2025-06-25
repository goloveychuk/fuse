import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import * as crypto from 'crypto';
import * as https from 'https';
import { tmpdir } from 'os';
import { pipeline } from 'stream/promises';
import { mkdir, mkdtemp } from 'fs/promises';
import * as tar from 'tar';

// @ts-ignore-error
import VERSIONS_DATA from './versions.json';

import type { VersionsData, PackageInfo } from './types';

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
  const expectedHash = Buffer.from(expectedHashBase64, 'base64');
  return async function* (s: NodeJS.ReadableStream) {
    const hash = crypto.createHash(algorithm);
    for await (const chunk of s) {
      hash.update(chunk);
      yield chunk;
    }
    const digest = hash.digest();
    if (Buffer.compare(digest, expectedHash) !== 0) {
      throw new Error(`Checksum mismatch`);
    }
  };
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

async function downloadAndExtractBinary(tarballUrl: string, integrity: string) {
  // Create a temporary directory for the download
  const tempDir = await mkdtemp(path.join(tmpdir(), 'fskit-binary-'));
  try {
    await pipeline(
      await createDownloadStream(tarballUrl),
      createHashCheckStream(integrity),
      tar.extract({
        cwd: tempDir,
        strict: true,
      }),
    );
  } catch (error) {
    fs.rmSync(tempDir, { recursive: true, force: true });
    throw error;
  }
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

// downloadAndExtractBinary(
//   'https://registry.npmjs.org/yarn-plugin-fuse-linux-arm64/-/yarn-plugin-fuse-linux-arm64-0.0.1.tgz',
//   'sha512-jm7ZZ/JoM/WZo2wBxJVhp1sPVJx5hpBZqWaLa1xpNDwamQsWoaISXM0f9Q4xHePXfamcEGVnxyQhm7fr8TFs3Q==',
// ).then(console.log);
