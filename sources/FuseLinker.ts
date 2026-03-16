import {
  Descriptor,
  FetchResult,
  formatUtils,
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
  setupCopyIndex,
  ppath,
  xfs,
  DirentNoPath,
  VirtualFS,
} from '@yarnpkg/fslib';
import { ZipOpenFS, ZipFS, JsZipImpl } from '@yarnpkg/libzip';
import { jsInstallUtils } from '@yarnpkg/plugin-pnp';
import { UsageError } from 'clipanion';
import { FuseNode } from './types';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as crypto from 'crypto';
import { getMounter, Mounter } from './mount';
import { Reflinks } from './reflinks';
import { MAGIC_HASH_FILE, withAtomic, PromiseOnce } from './common';
import { BuildConfigCache } from './buildConfigCache';

function assign(node: FuseNode, data: FuseNode) {
  Object.assign(node, data);
}

interface HoistConfig {
  levels?: number;
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

async function isPackageDirValid(pkgDir: string): Promise<boolean> {
  const hashFilePath = path.join(pkgDir, MAGIC_HASH_FILE);
  try {
    await fs.access(pkgDir);
  } catch {
    return false;
  }

  let expectedHash: string;
  try {
    expectedHash = await fs.readFile(hashFilePath, 'utf8');
  } catch {
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
  public dependenciesLocation: PortablePath | null;
  public packageLocation: PortablePath;
  public target: PortablePath | null;
  public isWorkspace: boolean;
  public locator: Locator;
  public _notPeerDepenendencies = new Map<IdentHash, Dependency>();
  public _peerDeps?: PeerDepsArray;
  constructor(data: {
    isWorkspace: boolean;
    target: PortablePath | null;
    packageLocation: PortablePath;
    locator: Locator;
    dependenciesLocation: PortablePath | null;
  }) {
    this.dependenciesLocation = data.dependenciesLocation;
    this.packageLocation = data.packageLocation;
    this.target = data.target;
    this.isWorkspace = data.isWorkspace;
    this.locator = data.locator;
  }

  *iterateAllDependencies(remapping: Remapping): IterableIterator<Dependency> {
    for (const [_, dep] of this._notPeerDepenendencies) {
      const remappedDependency = remapping.get(dep.locator.locatorHash);
      if (remappedDependency) {
        yield {
          descriptor: dep.descriptor,
          locator: remappedDependency.locator,
        };
      } else {
        yield dep;
      }
    }

    if (this._peerDeps) {
      let ind = 0;
      for (const [_, descriptor] of this._peerDeps._peerDepenenencies) {
        const mbDep = this._peerDeps.deps[ind];
        if (mbDep) {
          yield {
            descriptor,
            locator: mbDep,
          };
        }
        ind += 1;
      }
    }
  }
}

type AllDependencies = Map<LocatorHash, DependencyData>;

type Remapping = Map<LocatorHash, DependencyData>;

export type FuseCustomData = {
  locatorByPath: Map<PortablePath, string>;
  packagePathByLocator: Map<LocatorHash, PortablePath>;
};

interface PeerDepsArray {
  deps: (Locator | undefined | null)[];
  _peerDepenenencies: Map<IdentHash, Descriptor>;
  depsCount: number;
}

function checkDepsOverlap(a: PeerDepsArray, of: PeerDepsArray) {
  let isSuperset = false;
  const isSubset = a.deps.every((dep, ind) => {
    if (dep == null) {
      return true;
    }
    if (of.deps[ind] == null) {
      isSuperset = true;
      return true;
    }
    return of.deps[ind]!.locatorHash === dep.locatorHash;
  });
  if (isSubset) {
    if (isSuperset) {
      return 'superset';
    } else {
      return 'subset';
    }
  }
  return 'none';
}
interface PeersCombined {
  array: DependencyData[];
  procesed: boolean;
}

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

class PeersDedup {
  private remapping: Remapping = new Map();
  // this used to recursively process children and then parents, because child dep can be dedupped and change parent dedupe
  private peerDepsToProceedMap = new Map<LocatorHash, PeersCombined>();
  constructor(private virtualMapForDedupe: Map<LocatorHash, PeersCombined>) {}
  dedupeAndHoistDependencyArrays(deps: PeersCombined) {
    if (deps.procesed) {
      return;
    }
    deps.procesed = true;

    deps.array.sort((a, b) => b._peerDeps!.depsCount - a._peerDeps!.depsCount);
    const deduped: DependencyData[] = [];

    outer: for (let dep of deps.array) {
      dep._peerDeps!.deps.forEach((d, ind) => {
        if (d == null) {
          return;
        }
        const peerToProceed = this.peerDepsToProceedMap.get(d.locatorHash);
        if (peerToProceed) {
          this.peerDepsToProceedMap.delete(d.locatorHash);
          this.dedupeAndHoistDependencyArrays(peerToProceed);
        }
        const remapped = this.remapping.get(d.locatorHash);
        if (remapped) {
          dep._peerDeps!.deps[ind] = remapped.locator;
        }
      });
      for (const duppedDep of deduped) {
        const overlap = checkDepsOverlap(dep._peerDeps!, duppedDep._peerDeps!);
        if (overlap !== 'none') {
          this.remapping.set(dep.locator.locatorHash, duppedDep);
          if (overlap === 'superset') {
            dep._peerDeps!.deps.forEach((d, ind) => {
              if (duppedDep._peerDeps!.deps[ind] == null && d != null) {
                duppedDep._peerDeps!.deps[ind] = d;
              }
            });
          }
          continue outer;
        }
      }
      deduped.push(dep);
    }
    if (process.env.DEBUG_PEERS) {
      console.log(
        deduped.map((d) => ({
          locator: structUtils.stringifyLocator(d.locator),
          deps: d._peerDeps!.deps.map(
            (d) => d && structUtils.stringifyLocator(d),
          ),
        })),
      );
      console.log(`was: ${deps.array.length} now: ${deduped.length}`);
    }
  }

  dedupePeerDeps() {
    for (const deps of this.virtualMapForDedupe.values()) {
      for (const dep of deps.array) {
        if (this.peerDepsToProceedMap.has(dep.locator.locatorHash)) {
          throw new Error('Unexpected duplicate in virtualMapForDedupe');
        }
        this.peerDepsToProceedMap.set(dep.locator.locatorHash, deps);
      }
    }
    for (const deps of this.virtualMapForDedupe.values()) {
      this.dedupeAndHoistDependencyArrays(deps);
    }
    return this.remapping;
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
  private readonly asyncActions = new miscUtils.AsyncActions(5);
  private readonly globalUnpackOnce = new PromiseOnce();
  private readonly buildConfigCache = new BuildConfigCache();
  private fuseIsSupported: Promise<boolean>;
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

    this.allDependencies.set(
      pkg.locatorHash,
      new DependencyData({
        packageLocation,
        dependenciesLocation,
        isWorkspace,
        target: null,
        locator: pkg,
      }),
    );

    return {
      packageLocation,
      buildRequest: null,
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
    const archivePathExists = xfs.existsSync(realPath);

    let buildConfig =
      await this.buildConfigCache.getCachedBuildConfig(realPath);
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
      buildConfig = {
        manifest:
          (await Manifest.tryFind(fetchResult.prefixPath, {
            baseFs: fetchResult.packageFs,
          })) ?? new Manifest(),
        misc: {
          hasBindingGyp: jsInstallUtils.hasBindingGyp(fetchResult),
        },
      };
      await this.buildConfigCache.writeCachedBuildConfig(realPath, buildConfig);
    }

    const devirtualizedLocator: Locator = isVirtual
      ? structUtils.devirtualizeLocator(pkg)
      : pkg;
    const dependencyMeta = this.opts.project.getDependencyMeta(
      devirtualizedLocator,
      pkg.version,
    );
    const buildRequest = jsInstallUtils.extractBuildRequest(
      pkg,
      buildConfig,
      dependencyMeta,
      { configuration: this.opts.project.configuration },
    );

    const packagePaths = getPackagePaths(pkg, {
      project: this.opts.project,
      buildRequest,
      fuseIsSupported: await this.fuseIsSupported,
    });
    const packageLocation = packagePaths.packageLocation;

    this.customData.locatorByPath.set(
      packageLocation,
      structUtils.stringifyLocator(pkg),
    );

    this.allDependencies.set(
      pkg.locatorHash,
      new DependencyData({
        ...packagePaths,
        isWorkspace: false,
        locator: pkg,
        target: archivePathExists
          ? ppath.join(realPath, fetchResult.prefixPath)
          : null, // for conditional dependencies
      }),
    );

    // api.holdFetchResult(this.asyncActions.set(pkg.locatorHash, async () => {
    //   await xfs.mkdirPromise(packageLocation, {recursive: true});

    //   // Copy the package source into the <root>/n_m/.store/<hash> directory, so
    //   // that we can then create symbolic links to it later.
    //   await xfs.copyPromise(packageLocation, fetchResult.prefixPath, {
    //     baseFs: fetchResult.packageFs,
    //     overwrite: false,
    //     linkStrategy: {
    //       type: `HardlinkFromIndex`,
    //       indexPath: await this.indexFolderPromise,
    //       autoRepair: true,
    //     },
    //   });
    // }));

    return {
      packageLocation,
      buildRequest,
    };
  }
  private hoistDependencies(remapping: Remapping, hoistConfig: HoistConfig) {
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
        return [...data.iterateAllDependencies(remapping)].map(
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

  virtualMapForDedupe = new Map<LocatorHash, PeersCombined>();

  private getDependencyLink(
    dependencyData: DependencyData,
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
    const depDstPath = ppath.join(dependencyData.dependenciesLocation!, name);

    const depLinkPath = ppath.relative(
      ppath.dirname(depDstPath),
      depSrcPaths.packageLocation,
    );

    return {
      name,
      relative: depLinkPath,
      absolute: depSrcPaths.packageLocation,
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

    const { dependenciesLocation } = dependencyData;

    if (!dependenciesLocation) return;

    const realDepsMap = new Map(
      dependencies.map(([desc, loc]) => [
        desc.identHash,
        { descriptor: desc, locator: loc },
      ]),
    );

    const hasExplicitSelfDependency = realDepsMap.has(locator.identHash);

    if (structUtils.isVirtualLocator(locator)) {
      const pkg = this.opts.project.storedPackages.get(locator.locatorHash);
      if (!pkg) {
        throw new Error(
          `Assertion failed: Expected the package to have been registered (${structUtils.stringifyLocator(locator)})`,
        );
      }
      const orig = structUtils.devirtualizeLocator(locator);

      let depsCount = 0;

      const deps: PeerDepsArray['deps'] = [];
      for (const identHash of pkg.peerDependencies.keys()) {
        //assumption is that peerDependencies has same sorting for all virtual deps
        const realDep = realDepsMap.get(identHash);
        deps.push(realDep?.locator);
        if (realDep) {
          realDepsMap.delete(identHash);
          depsCount += 1;
        }
      }
      dependencyData._peerDeps = {
        deps,
        depsCount,
        _peerDepenenencies: pkg.peerDependencies,
      };
      if (!this.virtualMapForDedupe.has(orig.locatorHash)) {
        this.virtualMapForDedupe.set(orig.locatorHash, {
          array: [],
          procesed: false,
        });
      }
      this.virtualMapForDedupe
        .get(orig.locatorHash)!
        .array.push(dependencyData);
    }

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
    defaultFsLayer: VirtualFS,
    target: PortablePath,
    destPkgPath: PortablePath,
  ): Promise<void> {
    await withAtomic(destPkgPath, async (tmpDir) => {
      const tmp = tmpDir as PortablePath;
      await xfs.copyPromise(tmp, target, { baseFs: defaultFsLayer });
      const hash = await calculateDirHash(tmp);
      await xfs.changeFilePromise(ppath.join(tmp, MAGIC_HASH_FILE), hash);
    });
  }

  private async persistHardDependency(
    defaultFsLayer: VirtualFS,
    dependencyData: DependencyData,
    remapping: Remapping,
  ) {
    if (dependencyData.target) {
      const dirIsValid = await isPackageDirValid(
        dependencyData.packageLocation,
      );

      if (!dirIsValid) {
        await xfs.removePromise(dependencyData.packageLocation, {
          recursive: true,
        });
        if (await this.reflinks.isSupported()) {
          const devirtualized = structUtils.isVirtualLocator(
            dependencyData.locator,
          )
            ? structUtils.devirtualizeLocator(dependencyData.locator)
            : dependencyData.locator;
          const pkgKey = structUtils.slugifyLocator(devirtualized);
          const globalPkgPath = this.reflinks.getGlobalPackagePath(
            pkgKey,
          ) as PortablePath;
          await this.globalUnpackOnce.call(pkgKey, async () => {
            const globalDirIsValid = await isPackageDirValid(globalPkgPath);
            if (!globalDirIsValid) {
              await xfs.removePromise(globalPkgPath, { recursive: true }); //race condition, dont really care, it's corrupted package
              await this.atomicUnpack(
                defaultFsLayer,
                dependencyData.target as PortablePath,
                globalPkgPath,
              );
            }
          });
          await this.reflinks.cloneToLocal(
            globalPkgPath,
            dependencyData.packageLocation,
          );
        } else {
          await this.atomicUnpack(
            defaultFsLayer,
            dependencyData.target,
            dependencyData.packageLocation,
          );
        }
      }
    }
    if (!dependencyData.dependenciesLocation) {
      return;
    }
    await xfs.mkdirPromise(dependencyData.dependenciesLocation, {
      recursive: true,
    });

    // Retrieve what's currently inside the package's true nm folder. We
    // will use that to figure out what are the extraneous entries we'll
    // need to remove.
    const initialEntries = await getNodeModulesListing(
      dependencyData.dependenciesLocation,
    );
    const extraneous = new Map(initialEntries);

    const concurrentPromises: Array<Promise<void>> = [];

    for (const dep of dependencyData.iterateAllDependencies(remapping)) {
      const { name, relative, absolute } = this.getDependencyLink(
        dependencyData,
        dep,
      );
      const depDstPath = ppath.join(dependencyData.dependenciesLocation, name);

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
    concurrentPromises.push(
      cleanNodeModules(dependencyData.dependenciesLocation, extraneous),
    );
    await Promise.all(concurrentPromises);
  }

  async finalizeInstall() {
    // console.time('peers dedupe')
    const remapping = new PeersDedup(this.virtualMapForDedupe).dedupePeerDeps();
    // console.timeEnd('peers dedupe')
    const fuseData: FuseNode = {
      children: {},
      linkType: 'HARD',
    };
    // console.time('hoisted')
    this.hoistDependencies(remapping, { levels: this.opts.project.configuration.get(`hoistLevels`) })

    // console.log('count', [...hoisted.keys()].length)
    // console.log('count', [...hoisted.keys()].length)
    // console.log('hoisted', [...hoisted.keys()])

    const defaultFsLayer = new VirtualFS({
      baseFs: new ZipOpenFS({
        maxOpenFiles: 80,
        readOnlyArchives: true,
        customZipImplementation: JsZipImpl,
      }),
    });
    // const toPersist: DependencyData[] = [];

    const mountRoot = getStoreLocation(this.opts.project, { unplugged: false });
    const fuseIsSupported = await this.fuseIsSupported;
    let unmountPromise: Promise<void> | null = null;
    if (fuseIsSupported && xfs.existsSync(mountRoot)) {
      unmountPromise = this.mounter.unmount(mountRoot); //todo run it sooner
    }

    for (const [locatorHash, dependencyData] of this.allDependencies) {
      const remapped = remapping.get(locatorHash);
      this.customData.packagePathByLocator.set(
        locatorHash,
        remapped?.packageLocation ?? dependencyData.packageLocation,
      );
      if (remapped) {
        // it's was deduped. We don't need to persist it
        continue;
      }
      let relative = ppath.relative(mountRoot, dependencyData.packageLocation);

      if (relative.startsWith(`..`)) {
        // this is all packages which are outside mountroot. Which is
        //  hacky but works
        this.asyncActions.set(locatorHash, async () => {
          await this.persistHardDependency(
            defaultFsLayer,
            dependencyData,
            remapping,
          );
        });
        continue;
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

      if (dependencyData.dependenciesLocation) {
        const relative = ppath.relative(
          mountRoot,
          dependencyData.dependenciesLocation,
        );
        if (relative.startsWith(`..`)) {
          throw new Error(
            `Assertion failed: Expected the package to have been registered (${JSON.stringify(dependencyData)})`,
          );
        }

        const nodeModulesNode = getPathNode(fuseData, relative);
        for (const dep of dependencyData.iterateAllDependencies(remapping)) {
          const link = this.getDependencyLink(dependencyData, dep);
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

      for (const { dependenciesLocation } of this.allDependencies.values()) {
        if (!dependenciesLocation) continue;

        const subpath = ppath.contains(storeLocation, dependenciesLocation);
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

    // Wait for the package installs to catch up
    await this.asyncActions.wait();

    await removeIfEmpty(storeLocation);
    if (this.opts.project.configuration.get(`nodeLinker`) !== `node-modules`)
      await removeIfEmpty(getNodeModulesLocation(this.opts.project));

    if (await this.reflinks.isSupported(true)) {
      await this.reflinks.cleanup();
    }

    return {
      customData: this.customData,
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
) {
  const pkgKey = structUtils.slugifyLocator(locator);
  const shouldBuild = Boolean(buildRequest && !buildRequest.skipped);
  const storeLocation = getStoreLocation(project, {
    unplugged: shouldBuild || fuseIsSupported === false,
  });

  const packageLocation = ppath.join(storeLocation, pkgKey, `package`);
  const dependenciesLocation = ppath.join(
    storeLocation,
    pkgKey,
    Filename.nodeModules,
  );

  return { packageLocation, dependenciesLocation };
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
