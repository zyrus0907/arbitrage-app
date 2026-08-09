import coreWebVitals from 'eslint-config-next/core-web-vitals';
import typescript from 'eslint-config-next/typescript';

/**
 * `eslint-config-next` v16 ships native flat configs, so they are spread
 * directly — no `FlatCompat` shim.
 */
const config = [
  {
    ignores: ['.next/**', 'node_modules/**', 'next-env.d.ts', 'coverage/**'],
  },
  ...coreWebVitals,
  ...typescript,
];

export default config;
