import { fileURLToPath } from 'node:url';
import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  reactStrictMode: true,
  // Pin the workspace root. Without this, Turbopack infers it from the nearest
  // lockfile and can wander outside the repository on a developer machine.
  turbopack: {
    root: fileURLToPath(new URL('.', import.meta.url)),
  },
  // Fail the build on type errors. This is the framework default; stating it
  // prevents a future "just unblock the build" edit from passing unnoticed.
  // Lint is enforced as its own CI step (`npm run lint`).
  typescript: { ignoreBuildErrors: false },
};

export default nextConfig;
