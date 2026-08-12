/**
 * Decimal string → integer minor units, using the currency's own exponent
 * (AC2.6, §2.4).
 *
 * Deliberately string-based rather than `Math.round(value * 10 ** exponent)`:
 * `1.15 * 100` is `114.99999999999999` in IEEE 754, and rounding it is one more
 * place for a money bug to start. Shifting the decimal point in the string has
 * no such failure mode.
 *
 * In its own module, with no React import and no server import, so it is
 * unit-testable in isolation — the conversion is the part with the interesting
 * edge cases, and the exponents that matter (0 for JPY, 2 for GBP, 3 for KWD)
 * are all seeded and all exercised.
 *
 * T12 brings `src/lib/money/`, which owns currency arithmetic for the whole
 * product. This function is input parsing at a form boundary rather than
 * arithmetic on a value, and it is expected to be absorbed there.
 */

/** Returns NaN for anything that is not a plain non-negative decimal. */
export function toMinorUnits(input: string, exponent: number): number {
  const trimmed = input.trim();
  if (trimmed === '') return 0;
  if (!/^\d*(\.\d*)?$/.test(trimmed)) return Number.NaN;

  const [whole = '', fraction = ''] = trimmed.split('.');
  if (fraction.length > exponent) return Number.NaN;

  const value = Number(`${whole || '0'}${fraction.padEnd(exponent, '0')}`);
  return Number.isSafeInteger(value) ? value : Number.NaN;
}

/** The inverse, for rendering a stored value back into an input. */
export function fromMinorUnits(minor: number | null, exponent: number): string {
  if (minor === null) return '';
  if (exponent === 0) return String(minor);
  const digits = String(minor).padStart(exponent + 1, '0');
  return `${digits.slice(0, digits.length - exponent)}.${digits.slice(digits.length - exponent)}`;
}

/** Like `toMinorUnits`, but an empty input means "clear the value". */
export function toMinorUnitsOrNull(input: string, exponent: number): number | null {
  if (input.trim() === '') return null;
  return toMinorUnits(input, exponent);
}
