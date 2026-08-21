import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, cpSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { afterAll, describe, expect, it } from 'vitest';

/**
 * T11 finding F6 — the bundle scan must not present a full PASS when the
 * value-level assertion never executed.
 *
 * The script is run as a subprocess against a synthetic `.next/static` tree, so
 * these assert the real exit codes and the real output rather than a
 * reimplementation of its logic. The fake "secret" below is a locally invented
 * string; no real credential appears in this file, and none is needed.
 */
const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const script = join(repoRoot, 'scripts', 'scan-client-bundle.mjs');

const FAKE_KEY = 'not-a-real-key-0000000000000000000000';

const workspaces: string[] = [];

/** A throwaway repo root holding a copy of the script and a fake build. */
function makeWorkspace(bundleContents: string): string {
  const root = mkdtempSync(join(tmpdir(), 'scan-bundle-'));
  workspaces.push(root);
  mkdirSync(join(root, 'scripts'), { recursive: true });
  mkdirSync(join(root, '.next', 'static', 'chunks'), { recursive: true });
  cpSync(script, join(root, 'scripts', 'scan-client-bundle.mjs'));
  writeFileSync(join(root, '.next', 'static', 'chunks', 'app.js'), bundleContents, 'utf8');
  return root;
}

function runScan(root: string, env: Record<string, string>, args: string[] = []) {
  return spawnSync(process.execPath, [join(root, 'scripts', 'scan-client-bundle.mjs'), ...args], {
    // A deliberately bare environment: the point of most of these cases is
    // which variables are ABSENT, and inheriting the developer's shell would
    // make the result depend on whose machine ran it.
    env: { PATH: process.env.PATH ?? '', NODE_ENV: 'production', ...env },
    encoding: 'utf8',
  });
}

afterAll(() => {
  for (const root of workspaces) if (existsSync(root)) rmSync(root, { recursive: true, force: true });
});

describe('client bundle scan reporting', () => {
  it('reports INCOMPLETE, not PASS, when the required secret is absent', () => {
    const result = runScan(makeWorkspace('console.log("clean bundle");'), {});

    expect(result.status).toBe(2);
    expect(result.stderr).toContain('RESULT: INCOMPLETE');
    expect(result.stdout).not.toContain('RESULT: PASS');
  });

  it('exits 0 under --allow-incomplete but still refuses to claim a pass', () => {
    const result = runScan(makeWorkspace('console.log("clean bundle");'), {}, [
      '--allow-incomplete',
    ]);

    expect(result.status).toBe(0);
    expect(result.stderr).toContain('RESULT: INCOMPLETE');
    expect(result.stdout).not.toContain('RESULT: PASS');
  });

  it('reports PASS only when the value assertion actually executed', () => {
    const result = runScan(makeWorkspace('console.log("clean bundle");'), {
      SUPABASE_SERVICE_ROLE_KEY: FAKE_KEY,
    });

    expect(result.status).toBe(0);
    expect(result.stdout).toContain('RESULT: PASS');
    expect(result.stdout).toMatch(/SUPABASE_SERVICE_ROLE_KEY\s+executed/);
  });

  it('states which value assertions ran and which did not', () => {
    const result = runScan(makeWorkspace('console.log("clean bundle");'), {
      SUPABASE_SERVICE_ROLE_KEY: FAKE_KEY,
    });

    expect(result.stdout).toMatch(/STRIPE_SECRET_KEY\s+not set/);
    expect(result.stdout).toMatch(/CRON_SECRET\s+not set/);
  });

  it('treats a value too short to scan as not executed rather than as a pass', () => {
    const result = runScan(makeWorkspace('console.log("clean bundle");'), {
      SUPABASE_SERVICE_ROLE_KEY: 'short',
    });

    expect(result.status).toBe(2);
    expect(result.stderr).toContain('RESULT: INCOMPLETE');
    expect(result.stderr).toContain('too short to scan');
  });

  it('fails on a leaked value, and never echoes the value itself', () => {
    const result = runScan(makeWorkspace(`const k=${JSON.stringify(FAKE_KEY)};`), {
      SUPABASE_SERVICE_ROLE_KEY: FAKE_KEY,
    });

    expect(result.status).toBe(1);
    expect(result.stderr).toContain('RESULT: FAIL');
    expect(result.stderr).toContain('the VALUE of SUPABASE_SERVICE_ROLE_KEY');
    expect(result.stdout + result.stderr).not.toContain(FAKE_KEY);
  });

  it('still scans names and literals when no value is available', () => {
    const result = runScan(makeWorkspace('const claim="InNlcnZpY2Vfcm9sZSI";'), {});

    // A failure outranks incompleteness: the literal scan is independent of the
    // value scan, and it found something.
    expect(result.status).toBe(1);
    expect(result.stderr).toContain('RESULT: FAIL');
    expect(result.stderr).toContain('a service_role JWT claim');
  });

  it('still fails when a server-only variable NAME appears, with no value set', () => {
    const result = runScan(makeWorkspace('process.env.STRIPE_SECRET_KEY;'), {});

    expect(result.status).toBe(1);
    expect(result.stderr).toContain('the name STRIPE_SECRET_KEY');
  });

  it('refuses to scan at all when there is no build output', () => {
    const root = mkdtempSync(join(tmpdir(), 'scan-bundle-empty-'));
    workspaces.push(root);
    mkdirSync(join(root, 'scripts'), { recursive: true });
    cpSync(script, join(root, 'scripts', 'scan-client-bundle.mjs'));

    const result = runScan(root, { SUPABASE_SERVICE_ROLE_KEY: FAKE_KEY });

    expect(result.status).toBe(1);
    expect(result.stderr).toContain('No build output found');
  });
});
