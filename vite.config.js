import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  root: 'src/panel',
  plugins: [react()],
  build: {
    outDir: '../../dist/panel-bundle',
    emptyOutDir: true
  }
});
