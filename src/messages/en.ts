/**
 * The only place user-facing copy lives (ARCHITECTURE.md §4.2, §13).
 *
 * Components read keys from here rather than embedding strings, so translation
 * later is a data exercise rather than a rewrite. No currency symbol, no date
 * format and no country name belongs in this file.
 */
export const messages = {
  app: {
    name: 'Arbitrage',
    tagline: 'Defensible numbers for retail arbitrage.',
  },
  home: {
    heading: 'Arbitrage',
    body: 'Foundation build. No deals, accounts or payments exist yet.',
  },
} as const;

export type Messages = typeof messages;
