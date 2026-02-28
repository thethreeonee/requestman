import { mkdir, cp } from 'node:fs/promises';

await mkdir('dist/devtools', { recursive: true });

await Promise.all([
  cp('manifest.json', 'dist/manifest.json'),
  cp('src/background.js', 'dist/background.js'),
  cp('src/devtools/devtools.html', 'dist/devtools/devtools.html'),
  cp('src/devtools/devtools.js', 'dist/devtools/devtools.js')
]);
