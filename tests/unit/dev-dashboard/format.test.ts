import { describe, expect, it } from 'vitest';

import { UNANSWERED, formatCount } from '@/lib/dev-dashboard/format';

describe('formatCount', () => {
  it('renders a zero row count as a plain zero', () => {
    expect(formatCount(0)).toBe('0');
  });

  it('groups thousands', () => {
    expect(formatCount(1200)).toBe('1,200');
    expect(formatCount(12345)).toBe('12,345');
    expect(formatCount(1234567)).toBe('1,234,567');
  });

  it('renders a small count without decoration', () => {
    expect(formatCount(7)).toBe('7');
  });

  it('distinguishes an unanswered count from an empty table', () => {
    expect(formatCount(null)).toBe(UNANSWERED);
    expect(formatCount(null)).not.toBe(formatCount(0));
  });

  it('does not invent a number when handed a non-finite value', () => {
    expect(formatCount(Number.NaN)).toBe(UNANSWERED);
    expect(formatCount(Number.POSITIVE_INFINITY)).toBe(UNANSWERED);
  });
});
