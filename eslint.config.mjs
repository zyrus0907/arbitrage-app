import coreWebVitals from 'eslint-config-next/core-web-vitals';
import typescript from 'eslint-config-next/typescript';

/**
 * `eslint-config-next` v16 ships native flat configs, so they are spread
 * directly — no `FlatCompat` shim.
 */
const config = [
  {
    // `supabase/.temp/` is CLI-generated, git-ignored, per-machine state. The
    // local stack writes a bundled edge-runtime entrypoint there on
    // `db:start`/`db:reset`, and linting a generated bundle is noise.
    ignores: [
      '.next/**',
      'node_modules/**',
      'next-env.d.ts',
      'coverage/**',
      'supabase/.temp/**',
    ],
  },
  ...coreWebVitals,
  ...typescript,
];

export default config;
