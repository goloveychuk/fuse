/**
 * Type definitions for FSKit
 */

/**
 * Information about a binary package
 */
export interface PackageInfo {
  /** Package name */
  // name: string;
  /** Package version */
  // version: string;
  /** Operating system (darwin, linux, win32) */
  os: string;
  /** CPU architecture (x64, arm64) */
  arch: string;
  /** URL to download the npm package tarball */
  tarballUrl: string;
  /** Integrity checksum in the format 'algorithm-base64hash' */
  integrity: string;
}

/**
 * Structure of the versions.json file
 */
export interface VersionsData {
  packages: PackageInfo[];
}


export interface FuseNode {
    // name: string
    target?: string
    linkType: 'HARD' | 'SOFT'
    children: Record<string, FuseNode>
}



export interface FuseData {
    roots: Record<string, FuseNode>
}