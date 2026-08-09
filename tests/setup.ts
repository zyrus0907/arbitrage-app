import '@testing-library/jest-dom/vitest';

// `src/lib/env.ts` parses at module load and throws on a missing required
// variable — that is the point of it. Tests that import anything reaching env
// need a valid baseline; tests about failure call the parse functions directly.
process.env.NEXT_PUBLIC_SITE_URL ??= 'http://localhost:3000';
