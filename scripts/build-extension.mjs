import { cp } from 'node:fs/promises';

await cp('public/manifest.json', 'dist/manifest.json');
