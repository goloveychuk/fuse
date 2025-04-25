import {Plugin, SettingsType} from '@yarnpkg/core';
import {PortablePath}         from '@yarnpkg/fslib';

import {FuseLinker}           from './FuseLinker';

export {FuseLinker};

declare module '@yarnpkg/core' {
  interface ConfigurationValueMap {
    fuseStoreFolder: PortablePath;
    unpluggedFuseStoreFolder: PortablePath;
  }
}

const plugin: Plugin = {
  configuration: {
    fuseStoreFolder: {
      description: `By default, the store is stored in the 'node_modules/.store' of the project. Sometimes in CI scenario's it is convenient to store this in a different location so it can be cached and reused.`,
      type: SettingsType.ABSOLUTE_PATH,
      default: `./node_modules/.store`,
    },
    unpluggedFuseStoreFolder: {
      description: `By default, the store is stored in the 'node_modules/.store-unplugged' of the project. Sometimes in CI scenario's it is convenient to store this in a different location so it can be cached and reused.`,
      type: SettingsType.ABSOLUTE_PATH,
      default: `./node_modules/.store-unplugged`,
    },
  },
  linkers: [
    FuseLinker,
  ],
};

// eslint-disable-next-line arca/no-default-export
export default plugin;
