import { structUtils, LinkType, LocatorHash, Package, Descriptor, IdentHash, Project } from '@yarnpkg/core';
import {
  checkPeerOverlap,
  groupVirtualsByBase,
  getRawPeerResolutions,
  dedupeVirtualPackages,
  hoistPeerDeps,
  dedupeAndHoist,
} from '../dedupeUtils';

// ─── fixture builder ──────────────────────────────────────────────────────────

/**
 * Lightweight stand-in for Project. Only the three maps used by dedupe/hoist.
 */
interface FakeProject {
  storedPackages: Map<LocatorHash, Package>;
  storedResolutions: Map<string, LocatorHash>;
  accessibleLocators: Set<LocatorHash>;
}

function makeIdent(name: string, scope?: string) {
  return structUtils.makeIdent(scope ?? null, name);
}

function makeDesc(name: string, range: string, scope?: string) {
  return structUtils.makeDescriptor(makeIdent(name, scope), range);
}

function makeLocator(name: string, ref: string, scope?: string) {
  return structUtils.makeLocator(makeIdent(name, scope), ref);
}

/** Build a non-virtual (base) package stored in the project. */
function makeBasePkg(
  proj: FakeProject,
  name: string,
  version: string,
  scope?: string,
): Package {
  const locator = makeLocator(name, `npm:${version}`, scope);
  const pkg: Package = {
    ...locator,
    version,
    languageName: 'node',
    linkType: LinkType.HARD,
    dependencies: new Map(),
    peerDependencies: new Map(),
    dependenciesMeta: new Map(),
    peerDependenciesMeta: new Map(),
    bin: new Map(),
  };
  proj.storedPackages.set(locator.locatorHash, pkg);
  const desc = makeDesc(name, `npm:${version}`, scope);
  proj.storedResolutions.set(desc.descriptorHash, locator.locatorHash);
  proj.accessibleLocators.add(locator.locatorHash);
  return pkg;
}

interface VirtualPkgConfig {
  /** Unique string used as the virtual entropy hash. */
  hash: string;
  /** Peer dep name → resolved Package (null = missing). */
  peers: Record<string, Package | null>;
}

/**
 * Build a virtual package and register it plus its peer resolutions.
 * Peer descriptors that ARE resolved get a storedResolutions entry pointing
 * to the provided package's locatorHash.
 */
function makeVirtualPkg(
  proj: FakeProject,
  name: string,
  version: string,
  config: VirtualPkgConfig,
  scope?: string,
): Package {
  const virtualRef = `virtual:${config.hash}#npm:${version}`;
  const locator = makeLocator(name, virtualRef, scope);

  const peerDependencies = new Map<IdentHash, Descriptor>();
  const dependencies = new Map<IdentHash, Descriptor>();

  for (const [peerName, resolved] of Object.entries(config.peers)) {
    const peerDesc = makeDesc(peerName, '*');
    peerDependencies.set(peerDesc.identHash, peerDesc);

    if (resolved !== null) {
      // The dependency entry uses a unique descriptor that resolves to the peer's locator.
      const depDesc = makeDesc(peerName, `npm:${resolved.version ?? '0.0.0'}-for-${config.hash}`);
      proj.storedResolutions.set(depDesc.descriptorHash, resolved.locatorHash);
      dependencies.set(peerDesc.identHash, depDesc);
    }
  }

  const pkg: Package = {
    ...locator,
    version,
    languageName: 'node',
    linkType: LinkType.HARD,
    dependencies,
    peerDependencies,
    dependenciesMeta: new Map(),
    peerDependenciesMeta: new Map(),
    bin: new Map(),
  };

  proj.storedPackages.set(locator.locatorHash, pkg);
  proj.accessibleLocators.add(locator.locatorHash);
  return pkg;
}

function makeProject(): Project {
  return {
    storedPackages: new Map(),
    storedResolutions: new Map(),
    accessibleLocators: new Set(),
  } as Project
}

// ─── checkPeerOverlap ─────────────────────────────────────────────────────────

describe('checkPeerOverlap', () => {
  const X = 'hash-X' as LocatorHash;
  const Y = 'hash-Y' as LocatorHash;

  test('empty arrays → subset', () => {
    expect(checkPeerOverlap([], [])).toBe('subset');
  });

  test('both null slots → subset', () => {
    expect(checkPeerOverlap([null], [null])).toBe('subset');
  });

  test('a null, b has value → a is subset of b', () => {
    expect(checkPeerOverlap([null], [X])).toBe('subset');
  });

  test('a has value, b null → a is superset', () => {
    expect(checkPeerOverlap([X], [null])).toBe('superset');
  });

  test('both same value → subset (exact match)', () => {
    expect(checkPeerOverlap([X], [X])).toBe('subset');
  });

  test('different values → none (conflict)', () => {
    expect(checkPeerOverlap([X], [Y])).toBe('none');
  });

  test('multiple slots: all match → subset', () => {
    expect(checkPeerOverlap([X, Y], [X, Y])).toBe('subset');
  });

  test('multiple slots: a has extra at second → superset', () => {
    expect(checkPeerOverlap([X, Y], [X, null])).toBe('superset');
  });

  test('multiple slots: a missing second → subset', () => {
    expect(checkPeerOverlap([X, null], [X, Y])).toBe('subset');
  });

  test('conflict on first slot even when second is extra → none (conflict wins)', () => {
    expect(checkPeerOverlap([X, Y], [Y, null])).toBe('none');
  });

  test('a has extra at first, conflict at second → none', () => {
    expect(checkPeerOverlap([X, Y], [null, X])).toBe('none');
  });

  test('all null in a, all values in b → subset', () => {
    expect(checkPeerOverlap([null, null], [X, Y])).toBe('subset');
  });

  test('all values in a, all null in b → superset', () => {
    expect(checkPeerOverlap([X, Y], [null, null])).toBe('superset');
  });
});

// ─── groupVirtualsByBase ──────────────────────────────────────────────────────

describe('groupVirtualsByBase', () => {
  test('empty store → empty groups', () => {
    const groups = groupVirtualsByBase(new Map());
    expect(groups.size).toBe(0);
  });

  test('non-virtual package is skipped', () => {
    const proj = makeProject();
    makeBasePkg(proj, 'react', '18.0.0');
    const groups = groupVirtualsByBase(proj.storedPackages);
    expect(groups.size).toBe(0);
  });

  test('virtual without peer deps is skipped', () => {
    const proj = makeProject();
    // Virtual but no peer deps
    const locator = makeLocator('react', 'virtual:abc123#npm:18.0.0');
    const pkg: Package = {
      ...locator,
      version: '18.0.0',
      languageName: 'node',
      linkType: LinkType.HARD,
      dependencies: new Map(),
      peerDependencies: new Map(), // empty
      dependenciesMeta: new Map(),
      peerDependenciesMeta: new Map(),
      bin: new Map(),
    };
    proj.storedPackages.set(locator.locatorHash, pkg);
    const groups = groupVirtualsByBase(proj.storedPackages);
    expect(groups.size).toBe(0);
  });

  test('two virtuals of same base package → one group', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    const v1 = makeVirtualPkg(proj, 'react-dom', '18.0.0', { hash: 'aaa', peers: { react: react } });
    const v2 = makeVirtualPkg(proj, 'react-dom', '18.0.0', { hash: 'bbb', peers: { react: null } });

    const groups = groupVirtualsByBase(proj.storedPackages);
    expect(groups.size).toBe(1);
    const [group] = [...groups.values()];
    expect(group).toHaveLength(2);
    expect(group.map(p => p.locatorHash)).toEqual(
      expect.arrayContaining([v1.locatorHash, v2.locatorHash]),
    );
  });

  test('virtuals of different base packages → separate groups', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    makeVirtualPkg(proj, 'react-dom', '18.0.0', { hash: 'aaa', peers: { react } });
    makeVirtualPkg(proj, 'react-query', '5.0.0', { hash: 'bbb', peers: { react } });

    const groups = groupVirtualsByBase(proj.storedPackages);
    expect(groups.size).toBe(2);
    for (const pkgs of groups.values()) expect(pkgs).toHaveLength(1);
  });

  test('single virtual per package → group of 1', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    makeVirtualPkg(proj, 'react-dom', '18.0.0', { hash: 'aaa', peers: { react } });
    const groups = groupVirtualsByBase(proj.storedPackages);
    expect(groups.size).toBe(1);
    expect([...groups.values()][0]).toHaveLength(1);
  });
});

// ─── getRawPeerResolutions ────────────────────────────────────────────────────

describe('getRawPeerResolutions', () => {
  test('returns null for missing peer', () => {
    const proj = makeProject();
    const pkg = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react: null } });
    const res = getRawPeerResolutions(pkg, proj.storedResolutions);
    expect(res).toEqual([null]);
  });

  test('returns locatorHash for resolved peer', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    const pkg = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react } });
    const res = getRawPeerResolutions(pkg, proj.storedResolutions);
    expect(res).toEqual([react.locatorHash]);
  });

  test('mixed peers: some resolved, some missing', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    const pkg = makeVirtualPkg(proj, 'lib', '1.0.0', {
      hash: 'h1',
      peers: { react, 'react-dom': null },
    });
    const res = getRawPeerResolutions(pkg, proj.storedResolutions);
    expect(res).toHaveLength(2);
    expect(res).toContain(react.locatorHash);
    expect(res).toContain(null);
  });
});

// ─── dedupeVirtualPackages ────────────────────────────────────────────────────

describe('dedupeVirtualPackages', () => {
  test('no packages → returns 0', () => {
    const proj = makeProject();
    expect(dedupeVirtualPackages(proj)).toBe(0);
    expect(proj.storedPackages.size).toBe(0);
  });

  test('single virtual → returns 0, nothing changed', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    const v1 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react } });
    const before = proj.storedPackages.size;
    expect(dedupeVirtualPackages(proj)).toBe(0);
    expect(proj.storedPackages.size).toBe(before);
    expect(proj.storedPackages.has(v1.locatorHash)).toBe(true);
  });

  test('no virtual packages (only base) → returns 0', () => {
    const proj = makeProject();
    makeBasePkg(proj, 'react', '18.0.0');
    expect(dedupeVirtualPackages(proj)).toBe(0);
  });

  test('two identical virtuals → one deduped, returns 1', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    const v1 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react } });
    const v2 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h2', peers: { react } });

    expect(dedupeVirtualPackages(proj)).toBe(1);
    // Exactly one of the two survives
    const survivors = [v1, v2].filter(v => proj.storedPackages.has(v.locatorHash));
    expect(survivors).toHaveLength(1);
  });

  test('three identical virtuals → two deduped, returns 2', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react } });
    makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h2', peers: { react } });
    makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h3', peers: { react } });

    expect(dedupeVirtualPackages(proj)).toBe(2);
    const virtuals = [...proj.storedPackages.values()].filter(p =>
      structUtils.isVirtualLocator(p),
    );
    expect(virtuals).toHaveLength(1);
  });

  test('subset merged into survivor, returns 1', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    // v1 has react resolved, v2 has react missing → v2 is subset of v1
    const v1 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react, 'react-dom': null } });
    const v2 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h2', peers: { react: null, 'react-dom': null } });

    expect(dedupeVirtualPackages(proj)).toBe(1);
    // v2 was subset → deduped; v1 survives
    const virtuals = [...proj.storedPackages.values()].filter(p =>
      structUtils.isVirtualLocator(p),
    );
    expect(virtuals).toHaveLength(1);
  });

  test('superset merged: loser extra dep transferred to survivor', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    const reactDom = makeBasePkg(proj, 'react-dom', '18.0.0');
    // survivor: react resolved, react-dom missing
    const survivor = makeVirtualPkg(proj, 'lib', '1.0.0', {
      hash: 'h1',
      peers: { react, 'react-dom': null },
    });
    // loser: react resolved (same), react-dom resolved (superset)
    makeVirtualPkg(proj, 'lib', '1.0.0', {
      hash: 'h2',
      peers: { react, 'react-dom': reactDom },
    });

    expect(dedupeVirtualPackages(proj)).toBe(1);

    const reactDomIdent = makeIdent('react-dom');
    // survivor should now have react-dom dep transferred from the loser
    expect(survivor.dependencies.has(reactDomIdent.identHash)).toBe(true);
  });

  test('conflict → both survive, returns 0', () => {
    const proj = makeProject();
    const react18 = makeBasePkg(proj, 'react', '18.0.0');
    const react17 = makeBasePkg(proj, 'react', '17.0.0');
    makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react: react18 } });
    makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h2', peers: { react: react17 } });

    expect(dedupeVirtualPackages(proj)).toBe(0);
    const virtuals = [...proj.storedPackages.values()].filter(p =>
      structUtils.isVirtualLocator(p),
    );
    expect(virtuals).toHaveLength(2);
  });

  test('deduped loser removed from accessibleLocators', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    const v1 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react } });
    const v2 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h2', peers: { react } });

    expect(proj.accessibleLocators.has(v1.locatorHash)).toBe(true);
    expect(proj.accessibleLocators.has(v2.locatorHash)).toBe(true);

    dedupeVirtualPackages(proj);

    const survivors = [v1, v2].filter(v => proj.storedPackages.has(v.locatorHash));
    const losers = [v1, v2].filter(v => !proj.storedPackages.has(v.locatorHash));
    expect(survivors).toHaveLength(1);
    expect(losers).toHaveLength(1);
    expect(proj.accessibleLocators.has(losers[0].locatorHash)).toBe(false);
    expect(proj.accessibleLocators.has(survivors[0].locatorHash)).toBe(true);
  });

  test('storedResolutions updated to point to survivor', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    const v1 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react } });
    const v2 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h2', peers: { react } });

    // Add a consumer descriptor pointing to v2
    const consumerDesc = makeDesc('consumer', 'virtual:h2#npm:0.0.0');
    proj.storedResolutions.set(consumerDesc.descriptorHash, v2.locatorHash);

    dedupeVirtualPackages(proj);

    const survivor = proj.storedPackages.has(v1.locatorHash) ? v1 : v2;
    // The consumer should now resolve to the survivor
    expect(proj.storedResolutions.get(consumerDesc.descriptorHash)).toBe(survivor.locatorHash);
  });

  test('transitive dedupe: dep group processed first, then parent can dedupe', () => {
    const proj = makeProject();
    // Two versions of react (the dep that differs)
    const react18a = makeBasePkg(proj, 'react', '18.0.0');
    const react18b = makeBasePkg(proj, 'react', '18.0.0'); // same version, but a second locator (won't happen in practice but tests the path)

    // Actually simulate: two react-dom virtuals that BOTH get deduped to one
    const reactDomV1 = makeVirtualPkg(proj, 'react-dom', '18.0.0', { hash: 'rd1', peers: { react: react18a } });
    const reactDomV2 = makeVirtualPkg(proj, 'react-dom', '18.0.0', { hash: 'rd2', peers: { react: react18a } });

    // Two lib virtuals that each depend on one of the react-dom virtuals
    makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'l1', peers: { 'react-dom': reactDomV1 } });
    makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'l2', peers: { 'react-dom': reactDomV2 } });

    // react-dom virtuals are identical → dedupe them first → lib virtuals become identical → dedupe them too
    const removed = dedupeVirtualPackages(proj);
    expect(removed).toBe(2); // 1 react-dom + 1 lib

    const virtuals = [...proj.storedPackages.values()].filter(p =>
      structUtils.isVirtualLocator(p),
    );
    expect(virtuals).toHaveLength(2); // 1 react-dom survivor + 1 lib survivor
  });

  test('multiple independent groups deduped in same pass', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    const ws = makeBasePkg(proj, 'ws', '8.0.0');

    // Group 1: lib-a
    makeVirtualPkg(proj, 'lib-a', '1.0.0', { hash: 'a1', peers: { react } });
    makeVirtualPkg(proj, 'lib-a', '1.0.0', { hash: 'a2', peers: { react } });

    // Group 2: lib-b
    makeVirtualPkg(proj, 'lib-b', '1.0.0', { hash: 'b1', peers: { ws } });
    makeVirtualPkg(proj, 'lib-b', '1.0.0', { hash: 'b2', peers: { ws } });

    const removed = dedupeVirtualPackages(proj);
    expect(removed).toBe(2);
  });

  test('all-missing peers: two virtuals with all peers missing → identical, dedupe', () => {
    const proj = makeProject();
    makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react: null } });
    makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h2', peers: { react: null } });
    expect(dedupeVirtualPackages(proj)).toBe(1);
  });

  test('scoped packages grouped correctly', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    const v1 = makeVirtualPkg(proj, 'design-system', '1.0.0', { hash: 'h1', peers: { react } }, 'wix');
    const v2 = makeVirtualPkg(proj, 'design-system', '1.0.0', { hash: 'h2', peers: { react } }, 'wix');
    expect(dedupeVirtualPackages(proj)).toBe(1);
    const survivors = [v1, v2].filter(v => proj.storedPackages.has(v.locatorHash));
    expect(survivors).toHaveLength(1);
  });
});

// ─── hoistPeerDeps ────────────────────────────────────────────────────────────

describe('hoistPeerDeps', () => {
  test('single package in group → no change, returns false', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react } });
    expect(hoistPeerDeps(proj)).toBe(false);
  });

  test('all peers missing in all members → no change', () => {
    const proj = makeProject();
    const v1 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react: null } });
    const v2 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h2', peers: { react: null } });
    expect(hoistPeerDeps(proj)).toBe(false);
    // deps maps unchanged
    const reactIdent = makeIdent('react');
    expect(v1.dependencies.has(reactIdent.identHash)).toBe(false);
    expect(v2.dependencies.has(reactIdent.identHash)).toBe(false);
  });

  test('one has peer resolved, other missing, both agree → hoist fills missing', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    const v1 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react } });
    const v2 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h2', peers: { react: null } });

    expect(hoistPeerDeps(proj)).toBe(true);

    const reactIdent = makeIdent('react');
    // v2 should now have the react dep
    expect(v2.dependencies.has(reactIdent.identHash)).toBe(true);
    // The descriptor it got should resolve to react's locatorHash
    const hoistedDesc = v2.dependencies.get(reactIdent.identHash)!;
    expect(proj.storedResolutions.get(hoistedDesc.descriptorHash)).toBe(react.locatorHash);
    // v1 unchanged
    expect(v1.dependencies.has(reactIdent.identHash)).toBe(true);
  });

  test('two different resolutions → ambiguous, no hoist', () => {
    const proj = makeProject();
    const react18 = makeBasePkg(proj, 'react', '18.0.0');
    const react17 = makeBasePkg(proj, 'react', '17.0.0');
    const v1 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react: react18 } });
    const v2 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h2', peers: { react: react17 } });

    expect(hoistPeerDeps(proj)).toBe(false);
    // Both should keep their original resolutions
    const reactIdent = makeIdent('react');
    const r1 = proj.storedResolutions.get(v1.dependencies.get(reactIdent.identHash)!.descriptorHash);
    const r2 = proj.storedResolutions.get(v2.dependencies.get(reactIdent.identHash)!.descriptorHash);
    expect(r1).toBe(react18.locatorHash);
    expect(r2).toBe(react17.locatorHash);
  });

  test('three members: two agree on resolution, one missing → all three get the resolution', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    const v1 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react } });
    const v2 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h2', peers: { react } });
    const v3 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h3', peers: { react: null } });

    expect(hoistPeerDeps(proj)).toBe(true);

    const reactIdent = makeIdent('react');
    expect(v3.dependencies.has(reactIdent.identHash)).toBe(true);
    // v1 and v2 already had it
    expect(v1.dependencies.has(reactIdent.identHash)).toBe(true);
    expect(v2.dependencies.has(reactIdent.identHash)).toBe(true);
  });

  test('all already resolved → returns false', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react } });
    makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h2', peers: { react } });
    expect(hoistPeerDeps(proj)).toBe(false);
  });

  test('multiple peer slots: only unambiguous slot is hoisted', () => {
    const proj = makeProject();
    const react18 = makeBasePkg(proj, 'react', '18.0.0');
    const react17 = makeBasePkg(proj, 'react', '17.0.0');
    const ws = makeBasePkg(proj, 'ws', '8.0.0');

    // react is ambiguous (18 vs 17), ws is unambiguous (only v1 has it)
    const v1 = makeVirtualPkg(proj, 'lib', '1.0.0', {
      hash: 'h1',
      peers: { react: react18, ws },
    });
    const v2 = makeVirtualPkg(proj, 'lib', '1.0.0', {
      hash: 'h2',
      peers: { react: react17, ws: null },
    });

    expect(hoistPeerDeps(proj)).toBe(true);

    const reactIdent = makeIdent('react');
    const wsIdent = makeIdent('ws');

    // react: ambiguous → v2 keeps react17, v1 keeps react18
    const r1 = proj.storedResolutions.get(v1.dependencies.get(reactIdent.identHash)!.descriptorHash);
    const r2 = proj.storedResolutions.get(v2.dependencies.get(reactIdent.identHash)!.descriptorHash);
    expect(r1).toBe(react18.locatorHash);
    expect(r2).toBe(react17.locatorHash);

    // ws: unambiguous → v2 gets ws
    expect(v2.dependencies.has(wsIdent.identHash)).toBe(true);
  });
});

// ─── dedupeAndHoist (integration) ────────────────────────────────────────────

describe('dedupeAndHoist (integration)', () => {
  beforeEach(() => {
    jest.spyOn(console, 'log').mockImplementation(() => {});
  });
  afterEach(() => {
    jest.restoreAllMocks();
  });

  test('no-op on empty project', () => {
    const proj = makeProject();
    expect(() => dedupeAndHoist(proj)).not.toThrow();
    expect(proj.storedPackages.size).toBe(0);
  });

  test('hoist enables second dedupe pass (the @wix/font-picker pattern)', () => {
    // v1: react resolved, react-dom missing
    // v2: react resolved, react-dom resolved
    // After hoisting: both have react-dom → identical → dedupe
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    const reactDom = makeBasePkg(proj, 'react-dom', '18.0.0');

    const v1 = makeVirtualPkg(proj, 'font-picker', '1.0.0', {
      hash: 'fp1',
      peers: { react, 'react-dom': null },
    });
    const v2 = makeVirtualPkg(proj, 'font-picker', '1.0.0', {
      hash: 'fp2',
      peers: { react, 'react-dom': reactDom },
    });

    dedupeAndHoist(proj);

    // After hoist: react-dom filled into v1 → both identical → one deduped
    const survivors = [v1, v2].filter(v => proj.storedPackages.has(v.locatorHash));
    expect(survivors).toHaveLength(1);
  });

  test('conflict survives both passes', () => {
    const proj = makeProject();
    const react18 = makeBasePkg(proj, 'react', '18.0.0');
    const react17 = makeBasePkg(proj, 'react', '17.0.0');
    makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react: react18 } });
    makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h2', peers: { react: react17 } });

    dedupeAndHoist(proj);

    const virtuals = [...proj.storedPackages.values()].filter(p =>
      structUtils.isVirtualLocator(p),
    );
    expect(virtuals).toHaveLength(2);
  });

  test('pure dedupe (no hoist needed) works correctly', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react } });
    makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h2', peers: { react } });
    makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h3', peers: { react } });

    dedupeAndHoist(proj);

    const virtuals = [...proj.storedPackages.values()].filter(p =>
      structUtils.isVirtualLocator(p),
    );
    expect(virtuals).toHaveLength(1);
  });

  test('hoist + dedupe across multiple groups', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    const ws = makeBasePkg(proj, 'ws', '8.0.0');

    // lib-a: one has ws missing, other has ws
    makeVirtualPkg(proj, 'lib-a', '1.0.0', { hash: 'a1', peers: { react, ws } });
    makeVirtualPkg(proj, 'lib-a', '1.0.0', { hash: 'a2', peers: { react, ws: null } });

    // lib-b: identical, already dedupable without hoist
    makeVirtualPkg(proj, 'lib-b', '1.0.0', { hash: 'b1', peers: { ws } });
    makeVirtualPkg(proj, 'lib-b', '1.0.0', { hash: 'b2', peers: { ws } });

    dedupeAndHoist(proj);

    const virtuals = [...proj.storedPackages.values()].filter(p =>
      structUtils.isVirtualLocator(p),
    );
    // 1 lib-a survivor + 1 lib-b survivor
    expect(virtuals).toHaveLength(2);
  });

  test('storedResolutions consistent after full pass', () => {
    const proj = makeProject();
    const react = makeBasePkg(proj, 'react', '18.0.0');
    const reactDom = makeBasePkg(proj, 'react-dom', '18.0.0');

    const v1 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h1', peers: { react, 'react-dom': null } });
    const v2 = makeVirtualPkg(proj, 'lib', '1.0.0', { hash: 'h2', peers: { react, 'react-dom': reactDom } });

    // Consumer descriptor pointing to v1
    const consumerDesc = makeDesc('consumer', 'virtual:consumer-h1#npm:0.0.0');
    proj.storedResolutions.set(consumerDesc.descriptorHash, v1.locatorHash);

    // Another consumer pointing to v2
    const consumerDesc2 = makeDesc('consumer', 'virtual:consumer-h2#npm:0.0.0');
    proj.storedResolutions.set(consumerDesc2.descriptorHash, v2.locatorHash);

    dedupeAndHoist(proj);

    // Both consumer descriptors should point to the same surviving locator
    const resolved1 = proj.storedResolutions.get(consumerDesc.descriptorHash)!;
    const resolved2 = proj.storedResolutions.get(consumerDesc2.descriptorHash)!;
    expect(resolved1).toBe(resolved2);
    expect(proj.storedPackages.has(resolved1)).toBe(true);
  });
});
