import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import * as crypto from 'crypto';
import * as https from 'https';
import { tmpdir } from 'os';
import { pipeline } from 'stream/promises';
import {  mkdtemp } from 'fs/promises';
import * as tar from 'tar';

// @ts-ignore-error
import VERSIONS_DATA from './versions.json';

import type { PackageInfo } from './types';

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
export function getPackageInfoForPlatform(): PackageInfo | null {
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
  const matchingPackage = VERSIONS_DATA.packages.find(
    (pkg: PackageInfo) => pkg.os === packageOS && pkg.arch === arch,
  );

  if (!matchingPackage) {
    console.error(`No matching binary package found for ${packageOS}-${arch}`);
    return null;
  }

  return matchingPackage;
}

async function downloadAndExtractTarball(
  tarballUrl: string,
  integrity: string,
) {
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
  return path.join(tempDir, 'package');
}


export async function fetchArtifact(packageInfo: PackageInfo): Promise<string> {
  const dirPath = await downloadAndExtractTarball(
    packageInfo.tarballUrl,
    packageInfo.integrity,
  );

  return dirPath;
}

// downloadAndExtractTarball(
//   'https://registry.npmjs.org/yarn-plugin-fuse-linux-arm64/-/yarn-plugin-fuse-linux-arm64-0.0.4.tgz',
//   'sha512-abkxJ9g0zH/4yslgQy/CKYo8ftRNSQIKhdQwgYB+Y+qYnwreGbrv5PRFnqZl41BzSW5sR49KurLj7s4CX/IFtA==',
// ).then(console.log);
