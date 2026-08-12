/**
 * T10 — money input conversion (AC2.6).
 *
 * The rule the project states everywhere and this test enforces: the
 * minor-unit scale is `currencies.minor_unit_exponent`, read from the database,
 * and nothing anywhere assumes ×100. GBP is 2, JPY is 0, KWD is 3, and all
 * three are seeded, so all three are exercised here rather than only the one
 * the launch market happens to use.
 */
import { describe, expect, it } from 'vitest';

import { toMinorUnits } from '@/components/onboarding/minor-units';

describe('toMinorUnits — exponent 2 (GBP, USD, EUR)', () => {
  it.each([
    ['12.50', 1250],
    ['12.5', 1250],
    ['12', 1200],
    ['0.01', 1],
    ['0', 0],
    ['', 0],
    ['1000000', 100000000],
  ])('%s → %i', (input, expected) => {
    expect(toMinorUnits(input, 2)).toBe(expected);
  });

  it('does not go through floating point', () => {
    // `1.15 * 100` is 114.99999999999999 in IEEE 754. A rounding-based
    // implementation gets 115 by luck here and gets it wrong elsewhere; the
    // string shift has no such failure mode.
    expect(toMinorUnits('1.15', 2)).toBe(115);
    expect(toMinorUnits('8.29', 2)).toBe(829);
    expect(toMinorUnits('0.29', 2)).toBe(29);
  });

  it('rejects more decimal places than the currency has', () => {
    expect(toMinorUnits('12.345', 2)).toBeNaN();
  });
});

describe('toMinorUnits — exponent 0 (JPY)', () => {
  it('treats the typed number as whole minor units', () => {
    expect(toMinorUnits('1200', 0)).toBe(1200);
  });

  it('rejects any decimal at all', () => {
    expect(toMinorUnits('12.5', 0)).toBeNaN();
    expect(toMinorUnits('12.0', 0)).toBeNaN();
  });
});

describe('toMinorUnits — exponent 3 (KWD)', () => {
  it('scales by a thousand, not a hundred', () => {
    expect(toMinorUnits('12.5', 3)).toBe(12500);
    expect(toMinorUnits('0.001', 3)).toBe(1);
  });
});

describe('toMinorUnits — rejects anything that is not a plain positive decimal', () => {
  it.each(['-1', '1e3', '1,50', 'abc', '£12.50', '12.50.1', ' 12 50 '])('%s', (input) => {
    expect(toMinorUnits(input, 2)).toBeNaN();
  });
});
