// #!/usr/bin/env node

/**
 * FSKit Publishing Script
 *
 * This script publishes artifacts as separate npm packages:
 * - Package name: yarn-fuse-plugin-$OS-$ARCH
 * - Uses zx for running scripts
 * - Gets version from root package.json
 * - Adds --provenance flag
 * - Creates a JSON file with all tarball URLs and checksums from npm
 * - Writes results to sources/versions.json
 * - Builds and publishes the root package
 */

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { $, cd } from 'zx';
import type { PackageInfo, VersionsData } from './sources/types';



const rootDir = path.dirname(fileURLToPath(import.meta.url));

// Read the root package.json to get the version
const rootPackageJson = JSON.parse(
  fs.readFileSync(path.join(rootDir, 'package.json'), 'utf8'),
);


console.log(`FSKit Publishing Script - Version: ${rootPackageJson.version}`);

// Map of architecture to npm architecture string
const archMap = {
  x86_64: 'x64',
  amd64: 'x64',
  arm64: 'arm64',
  aarch64: 'arm64',
};

// Function to create temporary package for an artifact
async function createPackageForArtifact(artifactDir, osName, arch) {
  const normalizedArch = archMap[arch] || arch;

  const packageName = `${rootPackageJson.name}-${osName}-${normalizedArch}`;

  console.log(`Creating package: ${packageName}@${rootPackageJson.version}`);

  const packageDir = artifactDir;

  const packageConfig = {
    name: packageName,
    version: rootPackageJson.version,
    description: `FSKit Fuse binary for ${osName} on ${normalizedArch}`,
    os: [osName],
    cpu: [normalizedArch],
    // bin: {
    //   'yarn-fuse': `./${path.basename(binaryDestPath)}`,
    // },
    repository: rootPackageJson.repository,
    publishConfig: {
      access: 'public',
    },
  };

  fs.writeFileSync(
    path.join(packageDir, 'package.json'),
    JSON.stringify(packageConfig, null, 2),
  );

  // Create a simple README.md
  fs.writeFileSync(
    path.join(packageDir, 'README.md'),
    `# ${packageName}\n\nFSKit Fuse binary for ${osName} on ${normalizedArch}.\n`,
  );

  return { packageDir, packageName, normalizedArch };
}

async function retry<T>(fn: () => Promise<T>, retries = 3, delay = 5000): Promise<T> {
  let lastError: Error | null = null;
  for (let i = 0; i < retries; i++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error as Error;
      await new Promise(resolve => setTimeout(resolve, delay));
    }
  }
  throw lastError;
}


// Function to publish a package using npm via zx
async function publishPackage(packageInfo) {
  const { packageDir, packageName, normalizedArch } = packageInfo;
  console.log(`Publishing package from ${packageDir}...`);

  try {
    // Change directory to package directory
    cd(packageDir);

    // Use npm publish with provenance
    await $`npm publish --provenance`;

    // Get package details from npm registry including integrity checksum
    const npmViewResult = await retry(() => $`npm view ${packageName}@${rootPackageJson.version} --json`);
    const packageData = JSON.parse(npmViewResult.stdout.trim());

    // Get the tarball URL and integrity (checksum)
    const tarballUrl = packageData.dist.tarball;
    const integrity = packageData.dist.integrity;

    return {
      success: true,
      packageName,
      normalizedArch,
      tarballUrl,
      integrity,
    };
  } catch (error) {
    console.error(
      `Failed to publish package from ${packageDir}:`,
      error.message,
    );
    return { success: false, packageName, normalizedArch };
  } finally {
    // Change back to original directory
    cd(rootDir);
  }
}

// Function to build and publish the root package
async function publishRootPackage(versionsData) {
  console.log('\n--- Building and publishing root package ---');

  try {
    // Write versions data to sources/versions.json
    console.log('Writing versions data to sources/versions.json...');
    fs.writeFileSync(
      path.join(rootDir, 'sources', 'versions.json'),
      JSON.stringify(versionsData, null, 2),
    );

    // Run yarn build
    console.log('Running yarn build...');
    await $`yarn build`;

    // Publish the root package
    console.log('Publishing root package...');
    await $`npm publish --provenance`;

    return true;
  } catch (error) {
    console.error('Failed to publish root package:', error.message);
    return false;
  }
}

// Main function
async function main() {
  // Ensure the artifacts directory exists
  const artifactsDir = path.join(rootDir, 'artifacts');
  if (!fs.existsSync(artifactsDir)) {
    console.error(`Artifacts directory not found: ${artifactsDir}`);
    process.exit(1);
  }

  // Clean up any existing temporary packages
  const tmpPackagesDir = path.join(rootDir, 'tmp-packages');
  if (fs.existsSync(tmpPackagesDir)) {
    fs.rmSync(tmpPackagesDir, { recursive: true, force: true });
  }
  fs.mkdirSync(tmpPackagesDir, { recursive: true });

  // List all artifact directories
  console.log('Scanning artifacts directory...');
  const artifactEntries = fs.readdirSync(artifactsDir, { withFileTypes: true });
  const artifactDirs = artifactEntries
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name);

  console.log(
    `Found ${artifactDirs.length} artifact directories: ${artifactDirs.join(
      ', ',
    )}`,
  );
  if (artifactDirs.length === 0) {
    throw new Error('No artifact directories found');
  }

  const packageDataCollection: PackageInfo[] = [];

  for (const artifactName of artifactDirs) {
    // Extract OS and ARCH from artifact name (expected format: fskit-$ARCH)
    // Note: The OS would be 'linux' since we're building on ubuntu in the workflow
    const parts = artifactName.split('-');
    if (parts.length < 2) {
      throw new Error(`Invalid artifact name format: ${artifactName}`);
    }

    const arch = parts[1];
    const osName = 'linux'; // From the GitHub workflow, we know these are all built on Linux
    const artifactDir = path.join(artifactsDir, artifactName);

    console.log(
      `Processing artifact: ${artifactName} (OS: ${osName}, ARCH: ${arch})`,
    );

    // Create a package for this artifact
    const packageInfo = await createPackageForArtifact(
      artifactDir,
      osName,
      arch,
    );
    if (!packageInfo) {
      throw new Error(`Failed to create package for artifact: ${artifactName}`);
    }

    // Publish the package
    const result = await publishPackage(packageInfo);
    if (!result.success) {
      throw new Error(`Failed to publish package: ${packageInfo.packageName}`);
    }

    if (result.success) {
      packageDataCollection.push({
        // name: result.packageName,
        // version: rootPackageJson.version,
        os: osName,
        arch: result.normalizedArch,
        tarballUrl: result.tarballUrl,
        integrity: result.integrity,
      });
    }
  }

  // Create versions data
  const versionsData: VersionsData = {
    packages: packageDataCollection,
  };
  console.log(JSON.stringify(versionsData, null, 2));
  // Build and publish the root package
  const rootPublishSuccess = await publishRootPackage(versionsData);

  // Final status report
  if (!rootPublishSuccess) {
    throw new Error('Root package publish failed');
  }
}

// Run the main function
main().catch((error) => {
  console.error('Publish script failed:', error);
  process.exit(1);
});
