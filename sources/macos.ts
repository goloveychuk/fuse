import { spawn, spawnSync } from 'child_process';
import {parse} from 'fast-plist'
import path from 'path';
import { fileURLToPath } from 'url';

const res = spawnSync('hdiutil', ['info', '-plist'], {})

if (res.error) {
  console.error('Error running hdiutil:', res.error);
  process.exit(1);
}
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const imagePath = path.join(__dirname, '../fskit/dummy');
const output = res.stdout.toString();
const plist = parse(output)
for (const image of plist.images) {
  if (image['image-path'] == imagePath) {
    console.log('Found image:', image);
    console.log(image['system-entities'][0]['dev-entry']);
  }
}