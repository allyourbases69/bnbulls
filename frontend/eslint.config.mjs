// Flat config for ESLint 9 + Next 15. eslint-config-next 15.x still ships
// legacy (`.eslintrc`-shaped) configs, not native flat-config arrays — that
// only landed in eslint-config-next 16. FlatCompat is the documented bridge
// (see Next's ESLint docs) for using them under ESLint's flat config system.
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { FlatCompat } from '@eslint/eslintrc';

const dirnamePath = dirname(fileURLToPath(import.meta.url));

const compat = new FlatCompat({
  baseDirectory: dirnamePath,
});

const eslintConfig = [
  ...compat.extends('next/core-web-vitals', 'next/typescript'),
  {
    ignores: [
      '.next/**',
      'out/**',
      'dist/**',
      'node_modules/**',
      'public/**',
      'next-env.d.ts',
      // standalone node scripts (art-port verification etc), not app code —
      // run directly with `node`, not covered by the app's tsconfig.
      'scripts/**',
    ],
  },
];

export default eslintConfig;
