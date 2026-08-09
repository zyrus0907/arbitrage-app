import { describe, expect, it } from 'vitest';
import {
  EnvValidationError,
  parsePublicEnv,
  parseServerEnv,
} from '@/lib/env';

describe('env validation', () => {
  it('throws when a required public variable is absent', () => {
    expect(() => parsePublicEnv({})).toThrow(EnvValidationError);
  });

  it('names the missing variable in the error', () => {
    let issues: string[] = [];
    try {
      parsePublicEnv({});
    } catch (error) {
      issues = (error as EnvValidationError).issues;
    }
    expect(issues.join('\n')).toContain('NEXT_PUBLIC_SITE_URL');
  });

  it('throws when a required public variable is malformed', () => {
    expect(() => parsePublicEnv({ NEXT_PUBLIC_SITE_URL: 'not-a-url' })).toThrow(
      EnvValidationError,
    );
  });

  it('accepts a valid public environment', () => {
    expect(parsePublicEnv({ NEXT_PUBLIC_SITE_URL: 'https://example.test' })).toEqual({
      NEXT_PUBLIC_SITE_URL: 'https://example.test',
    });
  });

  it('rejects a present-but-empty server secret rather than treating it as unset', () => {
    expect(() =>
      parseServerEnv({ NODE_ENV: 'test', SUPABASE_SERVICE_ROLE_KEY: '' }),
    ).toThrow(EnvValidationError);
  });

  it('defaults NODE_ENV and leaves not-yet-required secrets optional', () => {
    expect(parseServerEnv({}).NODE_ENV).toBe('development');
  });
});
