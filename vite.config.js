// vite.config.ts
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { resolve } from 'node:path';

const buildTarget = process.env.BUILD_TARGET === 'firefox' ? 'firefox' : 'chrome';

export default defineConfig({
  // ✅ 关键：把 src 当成项目根
  root: resolve(__dirname, 'src'),

  plugins: [react()],

  // ✅ 扩展里必须相对路径
  base: './',

  // ✅ public 目录仍然使用项目根下的 /public（不在 src 里）
  publicDir: false,

  build: {
    // ✅ outDir 相对于 root=src，所以要写到 ../dist
    outDir: resolve(__dirname, `dist/${buildTarget}`),
    emptyOutDir: true,
    cssCodeSplit: true,
    chunkSizeWarningLimit: 1000,

    rollupOptions: {
      // ✅ 注意：这里的路径是相对于 root=src 的
      input: {
        requestman: resolve(__dirname, 'src/requestman/index.html'),
        devtools: resolve(__dirname, 'src/devtools/index.html'),

        // 纯脚本入口
        background: resolve(__dirname, 'src/background/index.ts'),
      },

      output: {
        manualChunks(id) {
          if (!id.includes('node_modules')) return;
          if (id.includes('/react/') || id.includes('/react-dom/')) return 'vendor-react';
          if (id.includes('/antd/') || id.includes('/@ant-design/')) return 'vendor-antd';
        },
        // ✅ 固定路径，避免 hash 和层级混乱
        entryFileNames: (chunk) => {
          const name = chunk.name;
          if (name === 'background') return 'background/index.js';
          return 'assets/[name].js';
        },
        chunkFileNames: 'assets/chunks/[name].js',
        assetFileNames: (assetInfo) => {
          const n = assetInfo.name || '';
          if (n.endsWith('.css')) return 'assets/[name][extname]';
          if (/\.(png|jpe?g|gif|svg|webp|ico)$/.test(n)) {
            return 'assets/[name][extname]';
          }
          return 'assets/[name][extname]';
        },
      },
    },
  },

  define: {
    'process.env': {},
  },
});
