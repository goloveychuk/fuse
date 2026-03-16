import {Plugin, SettingsType} from '@yarnpkg/core';
import {PortablePath}         from '@yarnpkg/fslib';

import {FuseLinker}           from './FuseLinker';
import CleanStoreCommand      from './commands/cleanStore';

export {FuseLinker};

declare module '@yarnpkg/core' {
  interface ConfigurationValueMap {
    fuseStoreFolder: PortablePath;
    unpluggedFuseStoreFolder: PortablePath;
    hoistLevels: number;
  }
}

const plugin: Plugin = {
  commands: [
    CleanStoreCommand,
  ],
  configuration: {
    fuseStoreFolder: {
      description: `By default, the store is stored in the 'node_modules/.store' of the project. Sometimes in CI scenario's it is convenient to store this in a different location so it can be cached and reused.`,
      type: SettingsType.ABSOLUTE_PATH,
      default: `./node_modules/.store-fuse`,
    },
    unpluggedFuseStoreFolder: {
      description: `By default, the store is stored in the 'node_modules/.store-unplugged' of the project. Sometimes in CI scenario's it is convenient to store this in a different location so it can be cached and reused.`,
      type: SettingsType.ABSOLUTE_PATH,
      default: `./node_modules/.store-fuse-unplugged`,
    },
    hoistLevels: {
      description: `By default hoisting is disabled. This can be configured to be enabled and the number of levels to hoist.`,
      type: SettingsType.NUMBER,
      default: 0,
    },
  },
  linkers: [
    FuseLinker,
  ],
};

// eslint-disable-next-line arca/no-default-export
export default plugin;
