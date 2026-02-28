import { cp } from 'node:fs/promises';

await cp('manifest.json', 'dist/manifest.json');
