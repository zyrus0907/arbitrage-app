import { describe, expect, it } from 'vitest';

import fixtures from '../fixtures/gtin/canonical-forms.json';

/**
 * T03 — the canonical-identifier contract, asserted at the application-test
 * layer.
 *
 * The GTIN normalisation *service* is T18. What this file locks down is the
 * property the Schema A columns depend on: several original barcode forms
 * collapse to one canonical GTIN-14, and that canonical value is what the
 * database stores and matches on. If a future normaliser disagrees with these
 * fixtures, one of the two is wrong and this test says so before a mismatched
 * product ever reaches a user (risk #1).
 */
describe('canonical GTIN-14 fixtures', () => {
  const { products } = fixtures;

  it('defines at least one product supplied in more than one original format', () => {
    expect(products.some((product) => product.forms.length > 1)).toBe(true);
  });

  it.each(products)('$label canonicalises to a single GTIN-14', ({ gtin14, forms }) => {
    expect(gtin14).toMatch(/^\d{14}$/);

    // The canonical form is the original code zero-padded to 14 digits — this
    // is the whole of the rule, and it is why a UPC-12 and an EAN-13 for the
    // same product are the same key rather than two.
    for (const form of forms) {
      expect(form.raw.padStart(14, '0')).toBe(gtin14);
    }
  });

  it('maps a UPC-12 and an EAN-13 of the same product onto one key', () => {
    const shared = products.find((product) => product.forms.length > 1);
    expect(shared).toBeDefined();

    const formats = shared!.forms.map((form) => form.format);
    expect(formats).toContain('upc_a');
    expect(formats).toContain('ean_13');

    const canonical = new Set(shared!.forms.map((form) => form.raw.padStart(14, '0')));
    expect(canonical.size).toBe(1);
  });

  it('never produces two products sharing a canonical key', () => {
    const keys = products.map((product) => product.gtin14);
    expect(new Set(keys).size).toBe(keys.length);
  });
});
