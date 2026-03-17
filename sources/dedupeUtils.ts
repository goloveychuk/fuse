import {
  Descriptor,
  IdentHash,
  LocatorHash,
  Package,
  Project,
  structUtils,
} from '@yarnpkg/core';

// ─── helpers ─────────────────────────────────────────────────────────────────

export function groupVirtualsByBase(
  storedPackages: Map<LocatorHash, Package>,
): Map<LocatorHash, Package[]> {
  const groups = new Map<LocatorHash, Package[]>();
  for (const pkg of storedPackages.values()) {
    if (!structUtils.isVirtualLocator(pkg) || pkg.peerDependencies.size === 0)
      continue;
    const baseHash = structUtils.devirtualizeLocator(pkg).locatorHash;
    const group = groups.get(baseHash);
    if (group) group.push(pkg);
    else groups.set(baseHash, [pkg]);
  }
  return groups;
}

export function getRawPeerResolutions(
  pkg: Package,
  storedResolutions: Map<string, LocatorHash>,
): (LocatorHash | null)[] {
  const result: (LocatorHash | null)[] = [];
  for (const [identHash] of pkg.peerDependencies) {
    const dep = pkg.dependencies.get(identHash);
    if (!dep) { result.push(null); continue; }
    const loc = storedResolutions.get(dep.descriptorHash);
    result.push(loc ?? null);
  }
  return result;
}

export function checkPeerOverlap(
  a: (LocatorHash | null)[],
  b: (LocatorHash | null)[],
): 'none' | 'subset' | 'superset' {
  let hasExtra = false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] == null) continue;
    if (b[i] == null) { hasExtra = true; continue; }
    if (a[i] !== b[i]) return 'none';
  }
  return hasExtra ? 'superset' : 'subset';
}

// ─── step 1: dedupe ──────────────────────────────────────────────────────────

export function dedupeVirtualPackages(project: Project): number {
  const { storedPackages, storedResolutions, accessibleLocators } = project;

  const groups = groupVirtualsByBase(storedPackages);

  const remapping = new Map<LocatorHash, LocatorHash>();

  function resolve(h: LocatorHash): LocatorHash {
    let cur = h;
    while (remapping.has(cur)) cur = remapping.get(cur)!;
    return cur;
  }

  function getPeerResolutions(pkg: Package): (LocatorHash | null)[] {
    const raw = getRawPeerResolutions(pkg, storedResolutions);
    return raw.map(h => (h != null ? resolve(h) : null));
  }

  const pkgToGroup = new Map<LocatorHash, LocatorHash>();
  for (const [baseHash, pkgs] of groups)
    for (const pkg of pkgs)
      pkgToGroup.set(pkg.locatorHash, baseHash);

  const processedGroups = new Set<LocatorHash>();

  function processGroup(baseHash: LocatorHash) {
    if (processedGroups.has(baseHash)) return;
    processedGroups.add(baseHash);

    const pkgs = groups.get(baseHash)!;
    if (pkgs.length <= 1) return;

    for (const pkg of pkgs) {
      for (const [identHash] of pkg.peerDependencies) {
        const dep = pkg.dependencies.get(identHash);
        if (!dep) continue;
        const locHash = storedResolutions.get(dep.descriptorHash);
        if (!locHash) continue;
        const depGroup = pkgToGroup.get(locHash);
        if (depGroup && !processedGroups.has(depGroup))
          processGroup(depGroup);
      }
    }

    const survivors: {
      pkg: Package;
      peerRes: (LocatorHash | null)[];
      peerIdents: IdentHash[];
    }[] = [];

    for (const pkg of pkgs) {
      if (remapping.has(pkg.locatorHash)) continue;

      const peerRes = getPeerResolutions(pkg);
      const peerIdents = [...pkg.peerDependencies.keys()];
      let merged = false;

      for (const survivor of survivors) {
        const overlap = checkPeerOverlap(peerRes, survivor.peerRes);
        if (overlap === 'none') continue;

        remapping.set(pkg.locatorHash, survivor.pkg.locatorHash);

        if (overlap === 'superset') {
          for (let i = 0; i < peerRes.length; i++) {
            if (survivor.peerRes[i] == null && peerRes[i] != null) {
              survivor.peerRes[i] = peerRes[i];
              const dep = pkg.dependencies.get(peerIdents[i]);
              if (dep) survivor.pkg.dependencies.set(peerIdents[i], dep);
            }
          }
        }

        merged = true;
        break;
      }

      if (!merged) survivors.push({ pkg, peerRes, peerIdents });
    }
  }

  for (const baseHash of groups.keys()) processGroup(baseHash);

  if (remapping.size === 0) return 0;

  for (const [descHash, locHash] of storedResolutions) {
    const resolved = resolve(locHash);
    if (resolved !== locHash) storedResolutions.set(descHash, resolved);
  }

  for (const loserHash of remapping.keys()) {
    storedPackages.delete(loserHash);
    accessibleLocators.delete(loserHash);
  }

  return remapping.size;
}

// ─── step 2: hoist compatible peer deps ──────────────────────────────────────

export function hoistPeerDeps(project: Project): boolean {
  const { storedPackages, storedResolutions } = project;
  const groups = groupVirtualsByBase(storedPackages);
  let changed = false;

  for (const pkgs of groups.values()) {
    if (pkgs.length <= 1) continue;

    const peerIdents = [...pkgs[0].peerDependencies.keys()];

    for (let i = 0; i < peerIdents.length; i++) {
      const identHash = peerIdents[i];

      let sharedLocHash: LocatorHash | null = null;
      let sharedDescriptor: Descriptor | null = null;
      let ambiguous = false;

      for (const pkg of pkgs) {
        const dep = pkg.dependencies.get(identHash);
        if (!dep) continue;
        const locHash = storedResolutions.get(dep.descriptorHash);
        if (!locHash) continue;

        if (sharedLocHash == null) {
          sharedLocHash = locHash;
          sharedDescriptor = dep;
        } else if (sharedLocHash !== locHash) {
          ambiguous = true;
          break;
        }
      }

      if (ambiguous || sharedLocHash == null || sharedDescriptor == null)
        continue;

      for (const pkg of pkgs) {
        if (pkg.dependencies.has(identHash)) continue;
        pkg.dependencies.set(identHash, sharedDescriptor);
        changed = true;
      }
    }
  }

  return changed;
}

// ─── combined pass ────────────────────────────────────────────────────────────

export function dedupeAndHoist(project: Project) {
  const { storedPackages } = project;

  let deduped = dedupeVirtualPackages(project);

  const hoisted = hoistPeerDeps(project);
  if (hoisted) {
    deduped += dedupeVirtualPackages(project);
  }

  // let totalVirtuals = 0;
  // const groups = groupVirtualsByBase(storedPackages);
  // for (const pkgs of groups.values()) totalVirtuals += pkgs.length;
  // const totalSurvivors = totalVirtuals;
  // const totalGroups = groups.size;

  // console.log(
  //   `Virtual dedupe: removed ${deduped} duplicates, ${totalSurvivors} virtual packages remain across ${totalGroups} unique base packages` +
  //     (hoisted ? ` (hoist enabled a second dedupe pass)` : ``),
  // );

  // for (const [baseHash, pkgs] of groups) {
  //   if (pkgs.length < 2) continue;

  //   const basePkg = storedPackages.get(baseHash) ?? pkgs[0];
  //   const baseName = structUtils.stringifyIdent(basePkg);
  //   console.log(`\n[SURVIVORS] ${baseName} — ${pkgs.length} instances remain:`);

  //   for (const pkg of pkgs) {
  //     const peerIdents = [...pkg.peerDependencies.keys()];
  //     const peerEntries = peerIdents.map(identHash => {
  //       const peerDesc = pkg.peerDependencies.get(identHash)!;
  //       const name = structUtils.stringifyIdent(peerDesc);
  //       const dep = pkg.dependencies.get(identHash);
  //       if (!dep) return `${name}=<missing>`;
  //       const locHash = project.storedResolutions.get(dep.descriptorHash);
  //       if (!locHash) return `${name}=<missing>`;
  //       const resolved = storedPackages.get(locHash);
  //       return `${name}=${resolved ? structUtils.stringifyLocator(resolved) : locHash}`;
  //     });
  //     console.log(`  ${structUtils.stringifyLocator(pkg)}`);
  //     console.log(`    peers: [${peerEntries.join(', ')}]`);
  //   }
  // }
}
