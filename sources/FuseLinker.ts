import { Descriptor, FetchResult, formatUtils, Installer, InstallPackageExtraApi, Linker, LinkOptions, LinkType, Locator, LocatorHash, Manifest, MessageName, MinimalLinkOptions, Package, Project, miscUtils, structUtils, WindowsLinkType, BuildRequest } from '@yarnpkg/core';
import { Filename, PortablePath, setupCopyIndex, ppath, xfs, DirentNoPath, VirtualFS } from '@yarnpkg/fslib';
import { ZipOpenFS } from '@yarnpkg/libzip';
import { jsInstallUtils } from '@yarnpkg/plugin-pnp';
import { UsageError } from 'clipanion';
import { FuseNode } from './types';
import * as fs from 'fs/promises'
import * as path from 'path'
import * as crypto from 'crypto';
import { getMounter, Mounter } from './mount';

function assign(node: FuseNode, data: FuseNode) {
  Object.assign(node, data);
}
const MAGIC_HASH_FILE = '.yarn-content-hash'

async function calculateDirHash(dirPath: string): Promise<string> {
  // Get all entries in the directory
  const entries = await fs.readdir(dirPath, { withFileTypes: true });

  // Sort entries for consistent hash generation regardless of read order
  entries.sort((a, b) => a.name.localeCompare(b.name));

  // Process all entries in parallel for better performance
  const entryHashes = await Promise.all(
    entries.map(async (entry) => {
      if (entry.name === MAGIC_HASH_FILE) {
        return ''
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
    })
  );

  // Filter out empty results and combine
  const combinedData = entryHashes.filter(Boolean).join('|');

  // Generate hash from combined data
  return crypto.createHash('sha256').update(combinedData).digest('hex');
}


interface DependencyData {
  isWorkspace: boolean;
  target: PortablePath | null;
  packageLocation: PortablePath;
  locator: Locator;
  dependenciesLocation: PortablePath | null;
  dependenciesLinks?: Map<PortablePath, { locator: Locator, relative: PortablePath, absolute: PortablePath }>;
}
export type FuseCustomData = {
  locatorByPath: Map<PortablePath, string>;
  allDependencies: Map<LocatorHash, DependencyData>;
};

export class FuseLinker implements Linker {
  getCustomDataKey() {
    return JSON.stringify({
      name: `FuseLinker`,
      version: 1,
    });
  }

  supportsPackage(pkg: Package, opts: MinimalLinkOptions) {
    return this.isEnabled(opts);
  }

  async findPackageLocation(locator: Locator, opts: LinkOptions) {
    if (!this.isEnabled(opts))
      throw new Error(`Assertion failed: Expected the fuse linker to be enabled`);

    const customDataKey = this.getCustomDataKey();
    const customData = opts.project.linkersCustomData.get(customDataKey) as FuseCustomData | undefined;
    if (!customData)
      throw new UsageError(`The project in ${formatUtils.pretty(opts.project.configuration, `${opts.project.cwd}/package.json`, formatUtils.Type.PATH)} doesn't seem to have been installed - running an install there might help`);

    const packagePaths = customData.allDependencies.get(locator.locatorHash);
    if (typeof packagePaths === `undefined`)
      throw new UsageError(`Couldn't find ${structUtils.prettyLocator(opts.project.configuration, locator)} in the currently installed fuse map - running an install might help`);

    return packagePaths.packageLocation;
  }

  async findPackageLocator(location: PortablePath, opts: LinkOptions): Promise<Locator | null> {
    if (!this.isEnabled(opts))
      return null;

    const customDataKey = this.getCustomDataKey();
    const customData = opts.project.linkersCustomData.get(customDataKey) as any;
    if (!customData)
      throw new UsageError(`The project in ${formatUtils.pretty(opts.project.configuration, `${opts.project.cwd}/package.json`, formatUtils.Type.PATH)} doesn't seem to have been installed - running an install there might help`);

    const nmRootLocation = location.match(/(^.*\/node_modules\/(@[^/]*\/)?[^/]+)(\/.*$)/);
    if (nmRootLocation) {
      const nmLocator = customData.locatorByPath.get(nmRootLocation[1]);
      if (nmLocator) {
        return nmLocator;
      }
    }

    let nextPath = location;
    let currentPath = location;
    do {
      currentPath = nextPath;
      nextPath = ppath.dirname(currentPath);

      const locator = customData.locatorByPath.get(currentPath);
      if (locator) {
        return locator;
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
      }
    }
    parent = parent.children[part];
  }
  return parent;
}

class FuseInstaller implements Installer {
  private readonly asyncActions = new miscUtils.AsyncActions(5);
  private readonly indexFolderPromise: Promise<PortablePath>;
  private fuseIsSupported: Promise<boolean>;
  private mounter: Mounter;
  constructor(private opts: LinkOptions) {
    this.indexFolderPromise = setupCopyIndex(xfs, {
      indexPath: ppath.join(opts.project.configuration.get(`globalFolder`), `index`),
    });
    this.mounter = getMounter();
    this.fuseIsSupported = this.mounter.supportsFuse();
  }

  private customData: FuseCustomData = {
    allDependencies: new Map(),
    locatorByPath: new Map(),
  };

  attachCustomData(customData: any) {
    // We don't want to attach the data because it's only used in the Linker and we'll recompute it anyways in the Installer,
    // it needs to be invalidated because otherwise we'll never prune the store or we might run into various issues.
  }

  async installPackage(pkg: Package, fetchResult: FetchResult, api: InstallPackageExtraApi) {
    // console.log('installPackage', structUtils.stringifyLocator(pkg));
    switch (pkg.linkType) {
      case LinkType.SOFT: return this.installPackageSoft(pkg, fetchResult, api);
      case LinkType.HARD: return this.installPackageHard(pkg, fetchResult, api);
    }

    throw new Error(`Assertion failed: Unsupported package link type`);
  }

  private async installPackageSoft(pkg: Package, fetchResult: FetchResult, api: InstallPackageExtraApi) {
    const packageLocation = ppath.resolve(fetchResult.packageFs.getRealPath(), fetchResult.prefixPath);

    const isWorkspace = this.opts.project.tryWorkspaceByLocator(pkg) !== null;
    const dependenciesLocation = isWorkspace
      ? ppath.join(packageLocation, Filename.nodeModules)
      : null;

    this.customData.allDependencies.set(pkg.locatorHash, {
      packageLocation,
      dependenciesLocation,
      isWorkspace,
      target: null,
      locator: pkg,
    });

    return {
      packageLocation,
      buildRequest: null,
    };
  }

  private async installPackageHard(pkg: Package, fetchResult: FetchResult, api: InstallPackageExtraApi) {
    const isVirtual = structUtils.isVirtualLocator(pkg);
    const devirtualizedLocator: Locator = isVirtual ? structUtils.devirtualizeLocator(pkg) : pkg;

    const buildConfig = {
      manifest: await Manifest.tryFind(fetchResult.prefixPath, { baseFs: fetchResult.packageFs }) ?? new Manifest(),
      misc: {
        hasBindingGyp: jsInstallUtils.hasBindingGyp(fetchResult),
      },
    };

    const dependencyMeta = this.opts.project.getDependencyMeta(devirtualizedLocator, pkg.version);
    const buildRequest = jsInstallUtils.extractBuildRequest(pkg, buildConfig, dependencyMeta, { configuration: this.opts.project.configuration });

    const packagePaths = getPackagePaths(pkg, { project: this.opts.project, buildRequest, fuseIsSupported: await this.fuseIsSupported });
    const packageLocation = packagePaths.packageLocation;

    this.customData.locatorByPath.set(packageLocation, structUtils.stringifyLocator(pkg));
    let realPath = fetchResult.packageFs.getRealPath();
    if (isVirtual) {
      realPath = VirtualFS.resolveVirtual(realPath);
    }

    this.customData.allDependencies.set(pkg.locatorHash, {
      ...packagePaths,
      isWorkspace: false,
      locator: pkg,
      target: xfs.existsSync(realPath) ? ppath.join(realPath, fetchResult.prefixPath) : null // for conditional dependencies
    });

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

  private getAllHoistedDependencies() {
      const visited = new Set<LocatorHash>()

      // const toVisit = [this.opts.project.topLevelWorkspace.anchoredLocator.locatorHash]
      const toVisit = [...this.opts.project.workspaces.map(w => w.anchoredLocator.locatorHash)]

      const hoisted = new Map<string, DependencyData>()

      while (toVisit.length) {
        const current = toVisit.pop()!
        if (visited.has(current)) {
          continue
        }
        visited.add(current)

        const data = this.customData.allDependencies.get(current) //probably disabled
        if (!data) {
          continue
        }
        const dependencyName = structUtils.stringifyIdent(data.locator)
        if (hoisted.has(dependencyName)) { //we skip deps here, sure?
          continue
        }
        if (!data.isWorkspace ) {
          hoisted.set(dependencyName, data)
        }

        // console.log('current', this.customData.allDependencies)
        if (data.dependenciesLinks) {
          for (const dep of data.dependenciesLinks.values()) {
              if (visited.has(dep.locator.locatorHash)) {
                continue
              }
              // const depName = structUtils.stringifyIdent(dep.locator)
              toVisit.push(dep.locator.locatorHash)
          }
        }
      }
      // console.log('hoisted', [...hoisted.keys()])
      return hoisted
  }

  async attachInternalDependencies(locator: Locator, dependencies: Array<[Descriptor, Locator]>) {
    if (this.opts.project.configuration.get(`nodeLinker`) !== `fuse`)
      return;

    // We don't install those packages at all, because they can't be used anyway
    if (!isPnpmVirtualCompatible(locator, { project: this.opts.project }))
      return;

    const dependencyData = this.customData.allDependencies.get(locator.locatorHash);
    if (typeof dependencyData === `undefined`)
      throw new Error(`Assertion failed: Expected the package to have been registered (${structUtils.stringifyLocator(locator)})`);

    const {
      dependenciesLocation,
    } = dependencyData;

    if (!dependenciesLocation)
      return;

    dependencyData.dependenciesLinks = new Map();

    const installDependency = (descriptor: Descriptor, dependency: Locator) => {
      // Downgrade virtual workspaces (cf isPnpmVirtualCompatible's documentation)
      let targetDependency = dependency;
      if (!isPnpmVirtualCompatible(dependency, { project: this.opts.project })) {
        this.opts.report.reportWarningOnce(MessageName.UNNAMED, `The fuse linker doesn't support providing different versions to workspaces' peer dependencies`);
        targetDependency = structUtils.devirtualizeLocator(dependency);
      }

      const depSrcPaths = this.customData.allDependencies.get(targetDependency.locatorHash);
      if (typeof depSrcPaths === `undefined`)
        throw new Error(`Assertion failed: Expected the package to have been registered (${structUtils.stringifyLocator(dependency)})`);

      const name = structUtils.stringifyIdent(descriptor) as PortablePath;
      const depDstPath = ppath.join(dependenciesLocation, name);

      const depLinkPath = ppath.relative(ppath.dirname(depDstPath), depSrcPaths.packageLocation);

      dependencyData.dependenciesLinks!.set(name, { relative: depLinkPath, absolute: depSrcPaths.packageLocation, locator: targetDependency });
    }

    let hasExplicitSelfDependency = false;
    for (const [descriptor, dependency] of dependencies) {
      if (descriptor.identHash === locator.identHash)
        hasExplicitSelfDependency = true;

      installDependency(descriptor, dependency);
    }

    if (!hasExplicitSelfDependency && !this.opts.project.tryWorkspaceByLocator(locator))
      installDependency(structUtils.convertLocatorToDescriptor(locator), locator);

  }

  async attachExternalDependents(locator: Locator, dependentPaths: Array<PortablePath>) {
    throw new Error(`External dependencies haven't been implemented for the fuse linker`);
  }


  private async isPackageValid(dependencyData: DependencyData) {
    const hashFilePath = ppath.join(dependencyData.packageLocation, MAGIC_HASH_FILE);
    if (!await xfs.existsPromise(dependencyData.packageLocation)) {
      return false
    }
    let expectedHash: string;
    try {
      expectedHash = await xfs.readFilePromise(hashFilePath, 'utf8');
    } catch {
      // hash is written after the package is copied, so if it doesn't exist, we assume the package is invalid
      return false
    }
    if (process.env.FORCE) {
      const existingHash = await calculateDirHash(dependencyData.packageLocation);
      if (expectedHash === existingHash) {
        return true
      } else {
        console.warn('Reinstalling', dependencyData.packageLocation);
        return false
      }
    }
    return true

  }

  private async persistHardDependency(defaultFsLayer: VirtualFS, dependencyData: DependencyData) {
    await xfs.mkdirPromise(dependencyData.packageLocation, { recursive: true });
    if (dependencyData.target) {
      const dirIsValid = await this.isPackageValid(dependencyData)
      if (!dirIsValid) {
        await xfs.removePromise(dependencyData.packageLocation, { recursive: true });
        await xfs.copyPromise(dependencyData.packageLocation, dependencyData.target, {
          baseFs: defaultFsLayer,
        });
        const hash = await calculateDirHash(dependencyData.packageLocation)
        const hashFilePath = ppath.join(dependencyData.packageLocation, MAGIC_HASH_FILE);
        await xfs.changeFilePromise(hashFilePath, hash);
      }

    }
    if (!dependencyData.dependenciesLocation) {
      return
    }
    await xfs.mkdirPromise(dependencyData.dependenciesLocation, { recursive: true });

    // Retrieve what's currently inside the package's true nm folder. We
    // will use that to figure out what are the extraneous entries we'll
    // need to remove.
    const initialEntries = await getNodeModulesListing(dependencyData.dependenciesLocation);
    const extraneous = new Map(initialEntries);

    const concurrentPromises: Array<Promise<void>> = [];

    for (const [name, { absolute, relative }] of dependencyData.dependenciesLinks!) {
      const depDstPath = ppath.join(dependencyData.dependenciesLocation, name);

      const existing = extraneous.get(name);
      extraneous.delete(name);

      concurrentPromises.push((async () => {
        if (existing) {
          if (existing.isSymbolicLink() && await xfs.readlinkPromise(depDstPath) === relative) {
            return;
          } else {
            await xfs.removePromise(depDstPath);
          }
        }

        await xfs.mkdirpPromise(ppath.dirname(depDstPath));
        if (process.platform == `win32` && this.opts.project.configuration.get(`winLinkType`) === WindowsLinkType.JUNCTIONS) {
          await xfs.symlinkPromise(absolute, depDstPath, `junction`);
        } else {
          await xfs.symlinkPromise(relative, depDstPath);
        }
      })());
    }
    concurrentPromises.push(cleanNodeModules(dependencyData.dependenciesLocation, extraneous));
    await Promise.all(concurrentPromises);
  }

  async finalizeInstall() {
    const fuseData: FuseNode = {
      children: {},
      linkType: 'HARD',
    }
    // console.time('hoisted')
    // const hoisted = this.getAllHoistedDependencies()
    // console.timeEnd('hoisted')
    // console.log('count', [...hoisted.keys()].length)
    // console.log('hoisted', [...hoisted.keys()])

    const defaultFsLayer = new VirtualFS({
      baseFs: new ZipOpenFS({
        maxOpenFiles: 80,
        readOnlyArchives: true,
      }),
    });
    // const toPersist: DependencyData[] = [];

    const mountRoot = getStoreLocation(this.opts.project, { unplugged: false });
    const fuseIsSupported = await this.fuseIsSupported;
    let unmountPromise: Promise<void> | null = null;
    if (fuseIsSupported) {
      unmountPromise = this.mounter.unmount(mountRoot); //todo run it sooner
    }

    for (const [locatorHash, dependencyData] of this.customData.allDependencies) {
      let relative = ppath.relative(mountRoot, dependencyData.packageLocation);

      if (relative.startsWith(`..`)) {
        // this is all packages which are outside mountroot. Which is 
        //  hacky but works
        this.asyncActions.set(locatorHash, async () => {
          await this.persistHardDependency(defaultFsLayer, dependencyData);
        });
        continue
      }

      // this are mocked packages. They don't have zip file. But maybe I should write it to disk to be consistent with unplugged behaviour.
      // const shouldMock = !!opts.mockedPackages?.has(locator.locatorHash) && (!this.check || !cacheFileExists);
      // shouldMock ? makeMockPackage(): Zipfs...
      if (this.opts.project.disabledLocators.has(locatorHash)) {
        continue
      }

      if (!dependencyData.target) {
        throw new Error(`Assertion failed: Expected the package to have target (${JSON.stringify(dependencyData)})`);
      }

      const node = getPathNode(fuseData, relative)

      assign(node, {
        children: {},
        linkType: 'HARD',
        target: dependencyData.target,
      })

      if (dependencyData.dependenciesLocation) {
        const relative = ppath.relative(mountRoot, dependencyData.dependenciesLocation);
        if (relative.startsWith(`..`)) {
          throw new Error(`Assertion failed: Expected the package to have been registered (${JSON.stringify(dependencyData)})`);
        }

        const nodeModulesNode = getPathNode(fuseData, relative)
        for (const [name, link] of dependencyData.dependenciesLinks!) {
          const node = getPathNode(nodeModulesNode, name)
          assign(node, {
            children: {},
            linkType: 'SOFT',
            target: link.relative,
          })
        }
      }
    }
    let promises: Promise<unknown>[] = []
    if (fuseIsSupported) {
      const fuseStatePath = ppath.join(
        this.opts.project.cwd,
        `.yarn/fuse-state.json`,
      );
      await unmountPromise;
      await xfs.changeFilePromise(fuseStatePath, JSON.stringify(fuseData), {});
      const upperDir = mountRoot + '.upper' as PortablePath
      if (!await xfs.existsPromise(mountRoot)) {
        await xfs.mkdirpPromise(mountRoot);
      }
      if (!await xfs.existsPromise(upperDir)) {
        await xfs.mkdirpPromise(upperDir);
      }
      promises.push(this.mounter.mount(mountRoot, fuseStatePath, upperDir));
    }
    await Promise.all([
      this.asyncActions.wait(),
      ...promises,
    ]);


    const storeLocation = getStoreLocation(this.opts.project, { unplugged: true });

    if (this.opts.project.configuration.get(`nodeLinker`) !== `fuse`) {
      await xfs.removePromise(storeLocation);
    } else {
      let extraneous: Set<Filename>;
      try {
        extraneous = new Set(await xfs.readdirPromise(storeLocation));
      } catch {
        extraneous = new Set();
      }

      for (const { dependenciesLocation } of this.customData.allDependencies.values()) {
        if (!dependenciesLocation)
          continue;

        const subpath = ppath.contains(storeLocation, dependenciesLocation);
        if (subpath === null)
          continue;

        const [storeEntry] = subpath.split(ppath.sep);
        extraneous.delete(storeEntry as Filename);
      }

      await Promise.all([...extraneous].map(async extraneousEntry => {
        await xfs.removePromise(ppath.join(storeLocation, extraneousEntry));
      }));
    }

    // Wait for the package installs to catch up
    await this.asyncActions.wait();

    await removeIfEmpty(storeLocation);
    if (this.opts.project.configuration.get(`nodeLinker`) !== `node-modules`)
      await removeIfEmpty(getNodeModulesLocation(this.opts.project));

    return {
      customData: this.customData,
    };
  }
}

function getNodeModulesLocation(project: Project) {
  return ppath.join(project.cwd, Filename.nodeModules);
}

function getStoreLocation(project: Project, { unplugged }: { unplugged: boolean }) {
  if (unplugged) {
    return project.configuration.get(`unpluggedFuseStoreFolder`);
  }

  return project.configuration.get(`fuseStoreFolder`);
}


function getPackagePaths(locator: Locator, { project, buildRequest, fuseIsSupported }: { project: Project, buildRequest: BuildRequest | null, fuseIsSupported: boolean }) {
  const pkgKey = structUtils.slugifyLocator(locator);
  const shouldBuild = Boolean(buildRequest && !buildRequest.skipped);
  const storeLocation = getStoreLocation(project, { unplugged: shouldBuild || fuseIsSupported === false });

  const packageLocation = ppath.join(storeLocation, pkgKey, `package`);
  const dependenciesLocation = ppath.join(storeLocation, pkgKey, Filename.nodeModules);

  return { packageLocation, dependenciesLocation };
}

function isPnpmVirtualCompatible(locator: Locator, { project }: { project: Project }) {
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

  return !structUtils.isVirtualLocator(locator) || !project.tryWorkspaceByLocator(locator);
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
      if (entry.name.startsWith(`.`))
        continue;

      if (entry.name.startsWith(`@`)) {
        const scopeListing = await xfs.readdirPromise(ppath.join(nmPath, entry.name), { withFileTypes: true });
        if (scopeListing.length === 0) {
          listing.set(entry.name, entry);
        } else {
          for (const subEntry of scopeListing) {
            listing.set(`${entry.name}/${subEntry.name}` as PortablePath, subEntry);
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

async function cleanNodeModules(nmPath: PortablePath, extraneous: Map<PortablePath, DirentNoPath>) {
  const removeNamePromises = [];
  const scopesToRemove = new Set<Filename>();

  for (const name of extraneous.keys()) {
    removeNamePromises.push(xfs.removePromise(ppath.join(nmPath, name)));

    const scope = structUtils.tryParseIdent(name)?.scope;
    if (scope) {
      scopesToRemove.add(`@${scope}` as Filename);
    }
  }

  return Promise.all(removeNamePromises).then(() => Promise.all([...scopesToRemove].map(
    scope => removeIfEmpty(ppath.join(nmPath, scope)),
  ))) as Promise<void>;
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
