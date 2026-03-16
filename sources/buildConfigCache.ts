import { Manifest } from '@yarnpkg/core';
import * as fs from 'fs/promises';
import * as crypto from 'crypto';

export type ExtractBuildScriptDataRequirements = {
  manifest: Pick<Manifest, `scripts`>;
  misc: {
    hasBindingGyp: boolean;
  };
};

interface Json {
    scripts: [string, string][];
    hasBindingGyp: boolean;
}

export class BuildConfigCache {
  async getCachedBuildConfig(
    realPath: string,
  ): Promise<ExtractBuildScriptDataRequirements | null> {

    try {
      const cachedBuildConfig = await fs.readFile(
        realPath + '.build-config.json',
        'utf8',
      );
      const json = JSON.parse(cachedBuildConfig) as Json;

      return {
        misc: {
          hasBindingGyp: json.hasBindingGyp,
        },
        manifest: {
          scripts: new Map(json.scripts),
        },
      };
    } catch (err) {
      return null;
    }
  }

  async writeCachedBuildConfig(
    realPath: string,
    buildConfig: ExtractBuildScriptDataRequirements,
  ) {
    let tmpFilePath = realPath + crypto.randomUUID();
    const json: Json = {
      scripts: Array.from(buildConfig.manifest.scripts.entries()),
      hasBindingGyp: buildConfig.misc.hasBindingGyp,
    };
    await fs.writeFile(tmpFilePath, JSON.stringify(json));
    try {
      await fs.rename(tmpFilePath, realPath + '.build-config.json');
    } catch (err: any) {
      if (err.code !== 'ENOTEMPTY' && err.code !== 'EEXIST') throw err;
      await fs.unlink(tmpFilePath);
    }
  }
}
