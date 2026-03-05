import { BaseCommand } from '@yarnpkg/cli';
import { Option, Usage } from 'clipanion';
import { Reflinks } from '../reflinks';
import { MAGIC_HASH_FILE } from '../common';

export default class CleanStoreCommand extends BaseCommand {
  static paths = [[`clean-pnpm-store`]];

  static usage: Usage = {
    description: `Clean unused packages from the global reflink store`,
    details: `
      Scans the global reflink store at ~/.yarn/berry/store-pnpm/ and identifies
      packages that are no longer referenced by any project (hardlink count of 1
      on the hash file).

      Use --dry to preview which packages would be removed without deleting anything.
    `,
  };

  dry = Option.Boolean(`--dry`, false, {
    description: `Only list packages that would be removed, without actually removing them`,
  });

  async execute(): Promise<void> {
    const unused = await Reflinks.findUnusedPackages(MAGIC_HASH_FILE);

    if (unused.length === 0) {
      this.context.stdout.write(`No unused packages in reflink store\n`);
      return;
    }

    if (this.dry) {
      const shown = unused.slice(0, 50);
      this.context.stdout.write(`${unused.length} unused packages would be removed:\n`);
      for (const name of shown) {
        this.context.stdout.write(`  ${name}\n`);
      }
      if (unused.length > 50) {
        this.context.stdout.write(`  ... and ${unused.length - 50} more\n`);
      }
      return;
    }

    Reflinks.removePackages(unused);
    this.context.stdout.write(`Scheduled ${unused.length} unused packages for removal\n`);
  }
}
