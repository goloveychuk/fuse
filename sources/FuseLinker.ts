import {
  Descriptor,
  FetchResult,
  formatUtils,
  FinalizeInstallStatus,
  Installer,
  InstallPackageExtraApi,
  Linker,
  LinkOptions,
  LinkType,
  Locator,
  LocatorHash,
  Manifest,
  MessageName,
  MinimalLinkOptions,
  Package,
  Project,
  miscUtils,
  structUtils,
  WindowsLinkType,
  BuildRequest,
  IdentHash,
} from '@yarnpkg/core';
import {
  Filename,
  PortablePath,
  ppath,
  xfs,
  DirentNoPath,
  VirtualFS,
} from '@yarnpkg/fslib';
import { ZipFS, JsZipImpl } from '@yarnpkg/libzip';
import { jsInstallUtils } from '@yarnpkg/plugin-pnp';
import { UsageError } from 'clipanion';
import { FuseNode } from './types';
import * as fs from 'fs/promises';
import * as fsSync from 'fs';
import * as path from 'path';
import * as crypto from 'crypto';
import { getMounter, Mounter } from './mount';
import { Reflinks } from './reflinks';
import isCI from 'is-ci';
import { MAGIC_HASH_FILE, withAtomic, PromiseOnce } from './common';
import {
  BuildConfigCache,
  ExtractBuildScriptDataRequirements,
} from './buildConfigCache';

// process.env.FUSE_PERF = 'true';
/**
 * Simple performance timer for debugging. Only active when FUSE_PERF=true.
 * Sums timings by name and prints a sorted report.
 */
// class FusePerf {
//   private readonly enabled = process.env.FUSE_PERF === 'true';
//   private readonly timings = new Map<string, number>();
//   private readonly counts = new Map<string, number>();
//   private readonly starts = new Map<string, number>();

//   start(name: string): () => void {
//     if (!this.enabled) return () => {};
//     const t = performance.now();
//     this.starts.set(name, t);
//     return () => {
//       const start = this.starts.get(name);
//       this.starts.delete(name);
//       const elapsed = start !== undefined ? performance.now() - start : 0;
//       this.timings.set(name, (this.timings.get(name) ?? 0) + elapsed);
//       this.counts.set(name, (this.counts.get(name) ?? 0) + 1);
//     };
//   }

//   async time<T>(name: string, fn: () => Promise<T>): Promise<T> {
//     const end = this.start(name);
//     try {
//       return await fn();
//     } finally {
//       end();
//     }
//   }

//   timeSync<T>(name: string, fn: () => T): T {
//     const end = this.start(name);
//     try {
//       return fn();
//     } finally {
//       end();
//     }
//   }

//   print(): void {
//     if (!this.enabled || this.timings.size === 0) return;
//     const entries = [...this.timings.entries()].sort((a, b) => b[1] - a[1]);
//     const total = entries.reduce((s, [, ms]) => s + ms, 0);
//     console.log('[FUSE_PERF] Timings (ms):');
//     for (const [name, ms] of entries) {
//       const count = this.counts.get(name);
//       const suffix = count !== undefined && count > 1 ? ` (×${count})` : '';
//       console.log(`  ${name}: ${ms.toFixed(2)}${suffix}`);
//     }
//     console.log(`  TOTAL: ${total.toFixed(2)}`);
//   }
// }

function assign(node: FuseNode, data: FuseNode) {
  Object.assign(node, data);
}

interface HoistConfig {
  levels?: number;
}

async function extractBuildScriptData(fetchResult: FetchResult) {
  return {
    manifest:
      (await Manifest.tryFind(fetchResult.prefixPath, {
        baseFs: fetchResult.packageFs,
      })) ?? new Manifest(),
    misc: {
      hasBindingGyp: jsInstallUtils.hasBindingGyp(fetchResult),
    },
  };
}
async function calculateDirHash(dirPath: string): Promise<string> {
  // Get all entries in the directory
  const entries = await fs.readdir(dirPath, { withFileTypes: true });

  // Sort entries for consistent hash generation regardless of read order
  entries.sort((a, b) => a.name.localeCompare(b.name));

  // Process all entries in parallel for better performance
  const entryHashes = await Promise.all(
    entries.map(async (entry) => {
      if (entry.name === MAGIC_HASH_FILE) {
        return '';
      }
      const entryPath = path.join(dirPath, entry.name);

      if (entry.isDirectory()) {
        // Recursively calculate hash for subdirectory
        const subDirHash = await calculateDirHash(entryPath);
        return `${entry.name}:dir:${subDirHash}`;
      } else if (entry.isFile()) {
        // Get file stats for mtime
        const stats = await fs.stat(entryPath, { bigint: true });
        return `${entry.name}:file:${stats.mtimeMs}`;
      }
      // Skip symlinks and special files
      return '';
    }),
  );

  // Filter out empty results and combine
  const combinedData = entryHashes.filter(Boolean).join('|');

  // Generate hash from combined data
  return crypto.createHash('sha256').update(combinedData).digest('hex');
}

async function isPackageDirValid(
  pkgDir: string,
  isFreshInstall: boolean,
): Promise<boolean> {
  if (isFreshInstall) {
    return false;
  }
  const hashFilePath = path.join(pkgDir, MAGIC_HASH_FILE);

  let expectedHash: string;
  try {
    expectedHash = await fs.readFile(hashFilePath, 'utf8');
  } catch (err) {
    return false;
  }

  if (process.env.FORCE) {
    const actualHash = await calculateDirHash(pkgDir);
    if (expectedHash !== actualHash) {
      console.warn('Reinstalling', pkgDir);
      return false;
    }
  }
  return true;
}

class DependencyData {
  public target: PortablePath | null;
  public isWorkspace: boolean;
  public locator: Locator;
  public _notPeerDepenendencies = new Map<IdentHash, Dependency>();
  public binEntries = new Map<string, string>();
  private _packagePathes?: PackagePathes;
  constructor(data: {
    isWorkspace: boolean;
    target: PortablePath | null;
    locator: Locator;
  }) {
    this.target = data.target;
    this.isWorkspace = data.isWorkspace;
    this.locator = data.locator;
  }

  set packagePathes(packagePathes: PackagePathes) {
    this._packagePathes = packagePathes;
  }
  get packagePathes(): PackagePathes {
    if (!this._packagePathes) {
      throw new Error('Package pathes are not set, bug');
    }
    return this._packagePathes;
  }

  *iterateAllDependencies(): IterableIterator<Dependency> {
    for (const [_, dep] of this._notPeerDepenendencies) {
      yield dep;
    }
  }
}

type AllDependencies = Map<LocatorHash, DependencyData>;

export type FuseCustomData = {
  locatorByPath: Map<PortablePath, string>;
  packagePathByLocator: Map<LocatorHash, PortablePath>;
};

interface Dependency {
  locator: Locator;
  descriptor: Descriptor;
}

function walkTree<T extends string>(
  initial: T[],
  fn: (node: T, depth: number) => Iterable<T> | undefined,
) {
  const visited = new Set<T>();
  const toVisit = [...initial.map((i) => [i, 0] as [T, number])];
  while (toVisit.length) {
    const [current, depth] = toVisit.pop()!;
    visited.add(current);
    const children = fn(current, depth);
    if (!children) {
      continue;
    }
    for (const child of children) {
      if (visited.has(child)) {
        continue;
      }
      toVisit.push([child, depth + 1]);
    }
  }
}

export class FuseLinker implements Linker {
  getCustomDataKey() {
    return JSON.stringify({
      name: `FuseLinker`,
      version: 2,
    });
  }

  supportsPackage(pkg: Package, opts: MinimalLinkOptions) {
    return this.isEnabled(opts);
  }

  async findPackageLocation(locator: Locator, opts: LinkOptions) {
    if (!this.isEnabled(opts))
      throw new Error(
        `Assertion failed: Expected the fuse linker to be enabled`,
      );

    const customDataKey = this.getCustomDataKey();
    const customData = opts.project.linkersCustomData.get(customDataKey) as
      | FuseCustomData
      | undefined;
    if (!customData)
      throw new UsageError(
        `The project in ${formatUtils.pretty(opts.project.configuration, `${opts.project.cwd}/package.json`, formatUtils.Type.PATH)} doesn't seem to have been installed - running an install there might help`,
      );

    const packageLocation = customData.packagePathByLocator.get(
      locator.locatorHash,
    );
    if (typeof packageLocation === `undefined`)
      throw new UsageError(
        `Couldn't find ${structUtils.prettyLocator(opts.project.configuration, locator)} in the currently installed fuse map - running an install might help`,
      );

    return packageLocation;
  }

  async findPackageLocator(
    location: PortablePath,
    opts: LinkOptions,
  ): Promise<Locator | null> {
    if (!this.isEnabled(opts)) return null;

    const customDataKey = this.getCustomDataKey();
    const customData = opts.project.linkersCustomData.get(customDataKey) as
      | FuseCustomData
      | undefined;
    if (!customData)
      throw new UsageError(
        `The project in ${formatUtils.pretty(opts.project.configuration, `${opts.project.cwd}/package.json`, formatUtils.Type.PATH)} doesn't seem to have been installed - running an install there might help`,
      );

    const nmRootLocation = location.match(
      /(^.*\/node_modules\/(@[^/]*\/)?[^/]+)(\/.*$)/,
    );
    if (nmRootLocation) {
      const nmLocator = customData.locatorByPath.get(
        nmRootLocation[1] as PortablePath,
      );
      if (nmLocator) {
        return structUtils.parseLocator(nmLocator);
      }
    }

    let nextPath = location;
    let currentPath = location;
    do {
      currentPath = nextPath;
      nextPath = ppath.dirname(currentPath);

      const locator = customData.locatorByPath.get(currentPath);
      if (locator) {
        return structUtils.parseLocator(locator);
      }
    } while (nextPath !== currentPath);

    return null;
  }

  makeInstaller(opts: LinkOptions) {
    return new FuseInstaller(opts);
  }

  private isEnabled(opts: MinimalLinkOptions) {
    return opts.project.configuration.get(`nodeLinker`) === `fuse`;
  }
}

const getPathNode = (start: FuseNode, path: PortablePath) => {
  const parts = path.split(ppath.sep);
  let parent = start;
  for (const part of parts) {
    if (!parent.children[part]) {
      parent.children[part] = {
        children: {},
        linkType: 'HARD',
      };
    }
    parent = parent.children[part];
  }
  return parent;
};

class FuseInstaller implements Installer {
  // private readonly perf = new FusePerf();
  private readonly asyncActions = new miscUtils.AsyncActions(isCI ? 20 : 5);
  private readonly globalUnpackOnce = new PromiseOnce();
  private readonly buildConfigCache = new BuildConfigCache();
  private fuseIsSupported: Promise<boolean>;
  private isFreshInstall: boolean;
  private readonly records: FinalizeInstallStatus[] = [];

  private mounter: Mounter;
  private reflinks: Reflinks;
  constructor(private opts: LinkOptions) {
    this.mounter = getMounter(opts.report);
    this.fuseIsSupported = process.env.FUSE
      ? this.mounter.supportsFuse().then((supported) => {
          if (supported) {
            opts.report.reportInfoOnce(
              MessageName.UNNAMED,
              `Fuse is supported`,
            );
          }
          return supported;
        })
      : Promise.resolve(false);
    const localStoreDir = getStoreLocation(opts.project, { unplugged: true });
    this.isFreshInstall = !fsSync.existsSync(
      getNodeModulesLocation(opts.project),
    );
    this.reflinks = new Reflinks(
      opts.project.configuration,
      opts.report,
      localStoreDir,
    );
  }

  private customData: FuseCustomData = {
    locatorByPath: new Map(),
    packagePathByLocator: new Map(),
  };
  private allDependencies: AllDependencies = new Map();

  attachCustomData(customData: any) {
    // We don't want to attach the data because it's only used in the Linker and we'll recompute it anyways in the Installer,
    // it needs to be invalidated because otherwise we'll never prune the store or we might run into various issues.
  }

  async installPackage(
    pkg: Package,
    fetchResult: FetchResult,
    api: InstallPackageExtraApi,
  ) {
    switch (pkg.linkType) {
      case LinkType.SOFT: {
        return this.installPackageSoft(pkg, fetchResult, api);
      }
      case LinkType.HARD: {
        return this.installPackageHard(pkg, fetchResult, api);
      }
      default:
        throw new Error(`Assertion failed: Unsupported package link type`);
    }
  }

  private async installPackageSoft(
    pkg: Package,
    fetchResult: FetchResult,
    api: InstallPackageExtraApi,
  ) {
    const packageLocation = ppath.resolve(
      fetchResult.packageFs.getRealPath(),
      fetchResult.prefixPath,
    );

    const isWorkspace = this.opts.project.tryWorkspaceByLocator(pkg) !== null;
    const dependenciesLocation = isWorkspace
      ? ppath.join(packageLocation, Filename.nodeModules)
      : null;

    const dependencyData = new DependencyData({
      isWorkspace,
      target: null,
      locator: pkg,
    });

    dependencyData.packagePathes = {
      packageLocation,
      dependenciesLocation,
      unplugged: true,
    };

    this.allDependencies.set(pkg.locatorHash, dependencyData);

    const manifest =
      (await Manifest.tryFind(fetchResult.prefixPath, {
        baseFs: fetchResult.packageFs,
      })) ?? new Manifest();
    dependencyData.binEntries = manifest.bin;

    return {
      packageLocation,
      buildRequest: null,
    };
  }
  private async getBuildConfig(
    pkg: Package,
    fetchResult: FetchResult,
    realPath: PortablePath,
    devirtualizedLocator: Locator,
    archivePathExists: boolean,
  ) {
    let buildConfig: ExtractBuildScriptDataRequirements | null = null;

    if (!isCI) {
      // because on ci we don't have any cache and don't do incremental installs
      buildConfig = await this.buildConfigCache.getCachedBuildConfig(realPath);
      if (!buildConfig) {
        // let packageFs = fetchResult.packageFs
        if (archivePathExists) {
          const packageFs = new ZipFS(realPath, {
            customZipImplementation: JsZipImpl,
            readOnly: true,
          });
          fetchResult = {
            ...fetchResult,
            packageFs,
          };
        }
        buildConfig = await extractBuildScriptData(fetchResult);
        await this.buildConfigCache.writeCachedBuildConfig(
          realPath,
          buildConfig,
        );
      }
    } else {
      buildConfig = await extractBuildScriptData(fetchResult);
    }

    const dependencyMeta = this.opts.project.getDependencyMeta(
      devirtualizedLocator,
      pkg.version,
    );

    return {
      buildRequest: jsInstallUtils.extractBuildRequest(
        pkg,
        buildConfig,
        dependencyMeta,
        { configuration: this.opts.project.configuration },
      ),
      manifest: buildConfig.manifest,
    };
  }

  private async installPackageHard(
    pkg: Package,
    fetchResult: FetchResult,
    api: InstallPackageExtraApi,
  ) {
    const isVirtual = structUtils.isVirtualLocator(pkg);
    let realPath = fetchResult.packageFs.getRealPath();
    if (isVirtual) {
      realPath = VirtualFS.resolveVirtual(realPath);
    }
    // const archivePathExists = this.opts.project.disabledLocators.has(pkg.locatorHash)
    const archivePathExists = xfs.existsSync(realPath);

    const orig: Locator = isVirtual
      ? structUtils.devirtualizeLocator(pkg)
      : pkg;

    const dependencyData = new DependencyData({
      // ...packagePaths,
      isWorkspace: false,
      locator: pkg,
      target: archivePathExists
        ? ppath.join(realPath, fetchResult.prefixPath)
        : null, // for conditional dependencies
    });

    this.allDependencies.set(pkg.locatorHash, dependencyData);

    let recordIndex = this.records.length;

    api.holdFetchResult(
      this.asyncActions.set(pkg.locatorHash, async () => {
        const { buildRequest, manifest } = await this.getBuildConfig(
          pkg,
          fetchResult,
          realPath,
          orig,
          archivePathExists,
        );
        const packagePaths = getPackagePaths(pkg, {
          project: this.opts.project,
          buildRequest,
          fuseIsSupported: await this.fuseIsSupported,
        });
        const packageLocation = packagePaths.packageLocation;

        if (buildRequest) {
          this.records[recordIndex] = {
            locator: pkg,
            buildLocations: [packageLocation],
            buildRequest,
          };
        }

        this.customData.locatorByPath.set(
          // im not sure if works with virtual
          packageLocation,
          structUtils.stringifyLocator(pkg),
        );

        if (packagePaths.unplugged && dependencyData.target) {
          await this.unpackHardDependency(
            fetchResult,
            dependencyData,
            packagePaths,
          );
        }

        dependencyData.packagePathes = packagePaths;
        dependencyData.binEntries = manifest.bin;
      }),
    );

    return {
      packageLocation: 'not-used' as PortablePath,
      buildRequest: null,
    };
  }
  private hoistDependencies(hoistConfig: HoistConfig) {
    if (!hoistConfig.levels) {
      return;
    }

    const hoisted = new Map<string, DependencyData>();

    walkTree(
      this.opts.project.workspaces.map((w) => w.anchoredLocator.locatorHash),
      (current, depth) => {
        const data = this.allDependencies.get(current); //probably disabled
        if (!data) {
          return;
        }
        const dependencyName = structUtils.stringifyIdent(data.locator);
        if (hoisted.has(dependencyName)) {
          //we skip deps here, sure?
          return;
        }
        if (!data.isWorkspace) {
          hoisted.set(dependencyName, data);
        }
        if (depth === hoistConfig.levels! - 1) {
          return;
        }
        return [...data.iterateAllDependencies()].map(
          (d) => d.locator.locatorHash,
        );
      },
    );
    let hoistedCount = 0;
    const rootDep = this.allDependencies.get(
      this.opts.project.topLevelWorkspace.anchoredLocator.locatorHash,
    )!;
    for (const d of hoisted.values()) {
      if (rootDep._notPeerDepenendencies.has(d.locator.identHash)) {
        continue;
      }
      rootDep._notPeerDepenendencies.set(d.locator.identHash, {
        descriptor: structUtils.convertLocatorToDescriptor(d.locator),
        locator: d.locator,
      });
      hoistedCount += 1;
    }
    this.opts.report.reportInfo(
      MessageName.UNNAMED,
      `Hoisted ${hoistedCount} dependencies`,
    );
  }

  private async persistBinSymlinks() {
    for (const dependencyData of this.allDependencies.values()) {
      if (!dependencyData.isWorkspace) continue;

      const nmLocation = dependencyData.packagePathes.dependenciesLocation;
      if (!nmLocation) continue;

      const binDir = ppath.join(nmLocation, `.bin` as Filename);
      const newBins = new Map<Filename, PortablePath>();

      for (const dep of dependencyData.iterateAllDependencies()) {
        let targetLocator = dep.locator;
        if (
          !isPnpmVirtualCompatible(targetLocator, {
            project: this.opts.project,
          })
        ) {
          targetLocator = structUtils.devirtualizeLocator(targetLocator);
        }

        const depData = this.allDependencies.get(targetLocator.locatorHash);
        if (!depData || depData.binEntries.size === 0) continue;

        for (const [binName, binScript] of depData.binEntries) {
          if (binScript === ``) continue;
          const target = ppath.join(
            depData.packagePathes.packageLocation,
            binScript as PortablePath,
          );
          newBins.set(binName as Filename, target);
        }
      }

      if (newBins.size === 0) {
        try {
          await xfs.removePromise(binDir);
        } catch {}
        continue;
      }

      await xfs.mkdirPromise(binDir, { recursive: true });

      let existing: Filename[] = [];
      try {
        existing = await xfs.readdirPromise(binDir);
      } catch {}

      for (const entry of existing) {
        if (!newBins.has(entry)) {
          await xfs.removePromise(ppath.join(binDir, entry));
        }
      }

      for (const [binName, target] of newBins) {
        const symlinkPath = ppath.join(binDir, binName);
        const relativePath = ppath.relative(binDir, target);

        try {
          const existingTarget = await xfs.readlinkPromise(symlinkPath);
          if (existingTarget === relativePath) continue;
          await xfs.removePromise(symlinkPath);
        } catch {}

        await xfs.symlinkPromise(relativePath, symlinkPath);
        try {
          await xfs.chmodPromise(target, 0o755);
        } catch {}
      }
    }
  }

  private getDependencyLink(
    packagePathes: PackagePathes,
    { locator: dependency, descriptor }: Dependency,
  ) {
    // Downgrade virtual workspaces (cf isPnpmVirtualCompatible's documentation)
    let targetDependency = dependency;
    if (!isPnpmVirtualCompatible(dependency, { project: this.opts.project })) {
      this.opts.report.reportWarningOnce(
        MessageName.UNNAMED,
        `The fuse linker doesn't support providing different versions to workspaces' peer dependencies`,
      );
      targetDependency = structUtils.devirtualizeLocator(dependency);
    }

    const depSrcPaths = this.allDependencies.get(targetDependency.locatorHash);
    if (typeof depSrcPaths === `undefined`)
      throw new Error(
        `Assertion failed: Expected the package to have been registered (${structUtils.stringifyLocator(dependency)})`,
      );

    const name = structUtils.stringifyIdent(descriptor) as PortablePath;
    const depDstPath = ppath.join(packagePathes.dependenciesLocation!, name);

    const depLinkPath = ppath.relative(
      ppath.dirname(depDstPath),
      depSrcPaths.packagePathes.packageLocation,
    );

    return {
      name,
      relative: depLinkPath,
      absolute: depSrcPaths.packagePathes.packageLocation,
    };
  }

  async attachInternalDependencies(
    locator: Locator,
    dependencies: Array<[Descriptor, Locator]>,
  ) {
    if (this.opts.project.configuration.get(`nodeLinker`) !== `fuse`) return;

    // We don't install those packages at all, because they can't be used anyway
    if (!isPnpmVirtualCompatible(locator, { project: this.opts.project }))
      return;

    const dependencyData = this.allDependencies.get(locator.locatorHash);
    if (typeof dependencyData === `undefined`)
      throw new Error(
        `Assertion failed: Expected the package to have been registered (${structUtils.stringifyLocator(locator)})`,
      );

    const realDepsMap = new Map(
      dependencies.map(([desc, loc]) => [
        desc.identHash,
        { descriptor: desc, locator: loc },
      ]),
    );

    const hasExplicitSelfDependency = realDepsMap.has(locator.identHash);

    if (
      !hasExplicitSelfDependency &&
      !this.opts.project.tryWorkspaceByLocator(locator)
    ) {
      realDepsMap.set(locator.identHash, {
        descriptor: structUtils.convertLocatorToDescriptor(locator),
        locator,
      });
    }
    dependencyData._notPeerDepenendencies = realDepsMap;
  }

  async attachExternalDependents(
    locator: Locator,
    dependentPaths: Array<PortablePath>,
  ) {
    throw new Error(
      `External dependencies haven't been implemented for the fuse linker`,
    );
  }

  private async atomicUnpack(
    fetchResult: FetchResult,
    destPkgPath: PortablePath,
  ): Promise<void> {
    await withAtomic(destPkgPath, async (tmpDir) => {
      const tmp = tmpDir as PortablePath;
      await xfs.copyPromise(tmp, fetchResult.prefixPath, {
        baseFs: fetchResult.packageFs,
      });
      const hash = await calculateDirHash(tmp);
      await xfs.changeFilePromise(ppath.join(tmp, MAGIC_HASH_FILE), hash);
    });
  }

  private async unpackHardDependency(
    fetchResult: FetchResult,
    dependencyData: DependencyData,
    packagePaths: PackagePathes,
  ) {
    const dirIsValid = await isPackageDirValid(
      packagePaths.packageLocation,
      this.isFreshInstall,
    );
    if (dirIsValid) {
      return;
    }
    await xfs.removePromise(packagePaths.packageLocation, {
      recursive: true,
    });
    if (await this.reflinks.isSupported()) {
      const devirtualized = structUtils.isVirtualLocator(dependencyData.locator)
        ? structUtils.devirtualizeLocator(dependencyData.locator)
        : dependencyData.locator;
      const pkgKey = structUtils.slugifyLocator(devirtualized);
      const globalPkgPath = this.reflinks.getGlobalPackagePath(
        pkgKey,
      ) as PortablePath;
      await this.globalUnpackOnce.call(pkgKey, async () => {
        const globalDirIsValid = await isPackageDirValid(
          globalPkgPath,
          this.isFreshInstall,
        );
        if (!globalDirIsValid) {
          await xfs.removePromise(globalPkgPath, { recursive: true }); //race condition, dont really care, it's corrupted package
          await this.atomicUnpack(fetchResult, globalPkgPath);
        }
      });
      await this.reflinks.cloneToLocal(
        globalPkgPath,
        packagePaths.packageLocation,
      );
    } else {
      await this.atomicUnpack(fetchResult, packagePaths.packageLocation);
    }
  }

  private async persistSymlinks(
    dependencyData: DependencyData,
    packagePaths: PackagePathes & { dependenciesLocation: PortablePath },
  ) {
    await xfs.mkdirPromise(packagePaths.dependenciesLocation, {
      recursive: true,
    });

    // Retrieve what's currently inside the package's true nm folder. We
    // will use that to figure out what are the extraneous entries we'll
    // need to remove.
    const initialEntries = await getNodeModulesListing(
      packagePaths.dependenciesLocation,
    );
    const extraneous = new Map(initialEntries);

    const concurrentPromises: Array<Promise<void>> = [];

    for (const dep of dependencyData.iterateAllDependencies()) {
      const { name, relative, absolute } = this.getDependencyLink(
        packagePaths,
        dep,
      );
      const depDstPath = ppath.join(packagePaths.dependenciesLocation, name);

      const existing = extraneous.get(name);
      extraneous.delete(name);

      concurrentPromises.push(
        (async () => {
          if (existing) {
            if (
              existing.isSymbolicLink() &&
              (await xfs.readlinkPromise(depDstPath)) === relative
            ) {
              return;
            } else {
              await xfs.removePromise(depDstPath);
            }
          }

          await xfs.mkdirpPromise(ppath.dirname(depDstPath));
          if (
            process.platform == `win32` &&
            this.opts.project.configuration.get(`winLinkType`) ===
              WindowsLinkType.JUNCTIONS
          ) {
            await xfs.symlinkPromise(absolute, depDstPath, `junction`);
          } else {
            await xfs.symlinkPromise(relative, depDstPath);
          }
        })(),
      );
    }
    if (!this.isFreshInstall) {
      concurrentPromises.push(
        cleanNodeModules(packagePaths.dependenciesLocation!, extraneous),
      );
    }
    await Promise.all(concurrentPromises);
  }

  async finalizeInstall() {
    // console.time('peers dedupe')
    // console.timeEnd('peers dedupe')
    const fuseData: FuseNode = {
      children: {},
      linkType: 'HARD',
    };
    // console.time('hoisted')

    await this.asyncActions.wait();

    await this.persistBinSymlinks();

    this.hoistDependencies({
      levels: this.opts.project.configuration.get(`hoistLevels`),
    });

    // console.log('count', [...hoisted.keys()].length)
    // console.log('count', [...hoisted.keys()].length)
    // console.log('hoisted', [...hoisted.keys()])

    // const defaultFsLayer = new VirtualFS({
    //   baseFs: new ZipOpenFS({
    //     maxOpenFiles: 80,
    //     readOnlyArchives: true,
    //   }),
    // });
    // const toPersist: DependencyData[] = [];

    const mountRoot = getStoreLocation(this.opts.project, { unplugged: false });
    const fuseIsSupported = await this.fuseIsSupported;
    let unmountPromise: Promise<void> | null = null;
    if (fuseIsSupported && xfs.existsSync(mountRoot)) {
      unmountPromise = this.mounter.unmount(mountRoot);
    }

    for (const [locatorHash, dependencyData] of this.allDependencies) {
      const packagePathes = dependencyData.packagePathes;
      this.customData.packagePathByLocator.set(
        locatorHash,
        packagePathes.packageLocation,
      );

      if (packagePathes.unplugged) {
        if (
          packagePathes.dependenciesLocation &&
          !this.opts.project.disabledLocators.has(locatorHash)
        ) {
          // link:./bla protocol does not have dependenciesLocation
          this.asyncActions.set(locatorHash + '__deps', async () => {
            await this.persistSymlinks(
              dependencyData,
              packagePathes as PackagePathes & {
                dependenciesLocation: PortablePath;
              },
            );
          });
        }
        continue;
      }
      let relative = ppath.relative(mountRoot, packagePathes.packageLocation);

      if (relative.startsWith(`..`)) {
        throw new Error(`Should not be here: ${relative}`);
      }

      // this are mocked packages. They don't have zip file. But maybe I should write it to disk to be consistent with unplugged behaviour.
      // const shouldMock = !!opts.mockedPackages?.has(locator.locatorHash) && (!this.check || !cacheFileExists);
      // shouldMock ? makeMockPackage(): Zipfs...
      if (this.opts.project.disabledLocators.has(locatorHash)) {
        continue;
      }

      if (!dependencyData.target) {
        throw new Error(
          `Assertion failed: Expected the package to have target (${JSON.stringify(dependencyData)})`,
        );
      }

      const node = getPathNode(fuseData, relative);

      assign(node, {
        children: {},
        linkType: 'HARD',
        target: dependencyData.target,
      });

      if (packagePathes.dependenciesLocation) {
        const relative = ppath.relative(
          mountRoot,
          packagePathes.dependenciesLocation,
        );
        if (relative.startsWith(`..`)) {
          throw new Error(
            `Assertion failed: Expected the package to have been registered (${JSON.stringify(dependencyData)})`,
          );
        }

        const nodeModulesNode = getPathNode(fuseData, relative);
        for (const dep of dependencyData.iterateAllDependencies()) {
          const link = this.getDependencyLink(packagePathes, dep);
          const node = getPathNode(nodeModulesNode, link.name);
          assign(node, {
            children: {},
            linkType: 'SOFT',
            target: link.relative,
          });
        }
      }
    }

    let promises: Promise<unknown>[] = [];
    if (fuseIsSupported) {
      const fuseStatePath = ppath.join(
        this.opts.project.cwd,
        `.yarn/fuse-state.json`,
      );
      await unmountPromise;
      await xfs.changeFilePromise(fuseStatePath, JSON.stringify(fuseData), {});
      const upperDir = (mountRoot + '.upper') as PortablePath;
      if (!(await xfs.existsPromise(mountRoot))) {
        await xfs.mkdirpPromise(mountRoot);
      }
      if (!(await xfs.existsPromise(upperDir))) {
        await xfs.mkdirpPromise(upperDir);
      }
      promises.push(this.mounter.mount(mountRoot, fuseStatePath, upperDir));
    }

    await Promise.all([this.asyncActions.wait(), ...promises]);

    const storeLocation = getStoreLocation(this.opts.project, {
      unplugged: true,
    });

    if (this.opts.project.configuration.get(`nodeLinker`) !== `fuse`) {
      await xfs.removePromise(storeLocation);
    } else {
      let extraneous: Set<Filename>;
      try {
        extraneous = new Set(await xfs.readdirPromise(storeLocation));
      } catch {
        extraneous = new Set();
      }

      for (const { packagePathes } of this.allDependencies.values()) {
        if (!packagePathes.dependenciesLocation) continue; //todo

        const subpath = ppath.contains(
          storeLocation,
          packagePathes.dependenciesLocation,
        );
        if (subpath === null) continue;

        const [storeEntry] = subpath.split(ppath.sep);
        extraneous.delete(storeEntry as Filename);
      }

      await Promise.all(
        [...extraneous].map(async (extraneousEntry) => {
          await xfs.removePromise(ppath.join(storeLocation, extraneousEntry));
        }),
      );
    }

    await removeIfEmpty(storeLocation);
    if (this.opts.project.configuration.get(`nodeLinker`) !== `node-modules`)
      await removeIfEmpty(getNodeModulesLocation(this.opts.project));

    if (await this.reflinks.isSupported(true)) {
      await this.reflinks.cleanup();
    }

    return {
      customData: this.customData,
      records: this.records.filter(Boolean),
    };
  }
}

function getNodeModulesLocation(project: Project) {
  return ppath.join(project.cwd, Filename.nodeModules);
}

function getStoreLocation(
  project: Project,
  { unplugged }: { unplugged: boolean },
) {
  if (unplugged) {
    return project.configuration.get(`unpluggedFuseStoreFolder`);
  }

  return project.configuration.get(`fuseStoreFolder`);
}

interface PackagePathes {
  packageLocation: PortablePath;
  dependenciesLocation: PortablePath | null;
  unplugged: boolean;
}

function getPackagePaths(
  locator: Locator,
  {
    project,
    buildRequest,
    fuseIsSupported,
  }: {
    project: Project;
    buildRequest: BuildRequest | null;
    fuseIsSupported: boolean;
  },
): PackagePathes {
  const pkgKey = structUtils.slugifyLocator(locator);
  const shouldBuild = Boolean(buildRequest && !buildRequest.skipped);
  const unplugged = shouldBuild || fuseIsSupported === false;
  const storeLocation = getStoreLocation(project, {
    unplugged,
  });

  const packageLocation = ppath.join(storeLocation, pkgKey, `package`);
  const dependenciesLocation = ppath.join(
    storeLocation,
    pkgKey,
    Filename.nodeModules,
  );

  return { packageLocation, dependenciesLocation, unplugged };
}

function isPnpmVirtualCompatible(
  locator: Locator,
  { project }: { project: Project },
) {
  // The pnpm install strategy has a limitation: because Node would always
  // resolve symbolic path to their true location, and because we can't just
  // copy-paste workspaces like we do with normal dependencies, we can't give
  // multiple dependency sets to the same workspace based on how its peer
  // dependencies are satisfied by its dependents (like PnP can).
  //
  // For this reason, we ignore all virtual instances of workspaces, and
  // instead have to rely on the user being aware of this caveat.
  //
  // TODO: Perhaps we could implement an error message when we detect multiple
  // sets in a way that can't be reproduced on disk?

  return (
    !structUtils.isVirtualLocator(locator) ||
    !project.tryWorkspaceByLocator(locator)
  );
}

async function getNodeModulesListing(nmPath: PortablePath) {
  const listing = new Map<PortablePath, DirentNoPath>();

  let fsListing: Array<DirentNoPath> = [];
  try {
    fsListing = await xfs.readdirPromise(nmPath, { withFileTypes: true });
  } catch (err: any) {
    if (err.code !== `ENOENT`) {
      throw err;
    }
  }

  try {
    for (const entry of fsListing) {
      if (entry.name.startsWith(`.`)) continue;

      if (entry.name.startsWith(`@`)) {
        const scopeListing = await xfs.readdirPromise(
          ppath.join(nmPath, entry.name),
          { withFileTypes: true },
        );
        if (scopeListing.length === 0) {
          listing.set(entry.name, entry);
        } else {
          for (const subEntry of scopeListing) {
            listing.set(
              `${entry.name}/${subEntry.name}` as PortablePath,
              subEntry,
            );
          }
        }
      } else {
        listing.set(entry.name, entry);
      }
    }
  } catch (err: any) {
    if (err.code !== `ENOENT`) {
      throw err;
    }
  }

  return listing;
}

async function cleanNodeModules(
  nmPath: PortablePath,
  extraneous: Map<PortablePath, DirentNoPath>,
) {
  const removeNamePromises = [];
  const scopesToRemove = new Set<Filename>();

  for (const name of extraneous.keys()) {
    removeNamePromises.push(xfs.removePromise(ppath.join(nmPath, name)));

    const scope = structUtils.tryParseIdent(name)?.scope;
    if (scope) {
      scopesToRemove.add(`@${scope}` as Filename);
    }
  }

  return Promise.all(removeNamePromises).then(() =>
    Promise.all(
      [...scopesToRemove].map((scope) =>
        removeIfEmpty(ppath.join(nmPath, scope)),
      ),
    ),
  ) as Promise<void>;
}

async function removeIfEmpty(dir: PortablePath) {
  try {
    await xfs.rmdirPromise(dir);
  } catch (error: any) {
    if (error.code !== `ENOENT` && error.code !== `ENOTEMPTY`) {
      throw error;
    }
  }
}
