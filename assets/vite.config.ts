// Reference: https://svelte.dev/docs/svelte/testing
import { defineConfig } from 'vitest/config';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import tailwindcss from '@tailwindcss/vite';
import path from 'path';

export default defineConfig({
  plugins: [
    tailwindcss(),
    svelte()
  ],
  resolve: {
    alias: {
      '$lib': path.resolve(__dirname, './src/lib'),
      '$components': path.resolve(__dirname, './src/lib/components'),
    }
  },
  test: {
    environment: 'jsdom',
    setupFiles: ['./src/setupTest.ts'],
    globals: true,
  },
  build: {
    target: 'esnext',
    outDir: '../priv/static/assets',
    emptyOutDir: false,
    sourcemap: true,
    rollupOptions: {
      input: {
        app: path.resolve(__dirname, './js/app.js'),
        piano_roll: path.resolve(__dirname, './src/piano_roll.ts'),
        node_editor: path.resolve(__dirname, './src/node_editor.ts'),
        arranger: path.resolve(__dirname, './src/arranger.ts')
      },
      output: {
        entryFileNames: '[name].js',
        chunkFileNames: 'chunks/[name]-[hash].js',
        assetFileNames: '[name][extname]'
      }
    }
  }
});