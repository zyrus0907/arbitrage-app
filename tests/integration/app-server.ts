/**
 * T10 — a real Next.js server, driven over real HTTP, with a real cookie jar.
 *
 * WHY THIS EXISTS RATHER THAN CALLING `proxy()` DIRECTLY
 *
 * Most of T10's auth criteria are statements about HTTP: a logged-out visitor
 * is *redirected* and *returned* to the intended route; the session lives in
 * *httpOnly cookies* and nothing else; sign-out *clears access*; a deleted
 * account's old session *cannot continue* reaching protected content. Every one
 * of those is a property of the response headers, and none of them can be
 * proved by importing a function and passing it a hand-built request — the
 * hand-built request is where the bug would be.
 *
 * So the suite starts the actual application, pointed at the local Supabase
 * stack, and talks to it with `fetch` and a cookie jar that follows the same
 * rules a browser does. If the cookie were not httpOnly, this harness would
 * still see it (it reads `set-cookie` directly) — which is exactly why the
 * flags are asserted explicitly rather than inferred from behaviour.
 *
 * WHY `next dev` AND NOT `next build && next start`
 *
 * `NEXT_PUBLIC_*` variables are inlined into the client bundle at BUILD time.
 * The committed `.env.local` points at the hosted development project, so a
 * production build would bake the hosted URL into the bundle and this suite
 * would silently test against the wrong database. `next dev` resolves the
 * environment per request, so the overrides below actually take effect. The
 * same technique T08 used to check the dev dashboard against the local stack.
 *
 * The server is started once per file and torn down in `afterAll`, including
 * on failure.
 */
import { spawn, type ChildProcess } from 'node:child_process';
import { createServer } from 'node:net';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { localStack } from './supabase-local';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');

export type AppServer = {
  origin: string;
  stop: () => Promise<void>;
};

async function freePort(): Promise<number> {
  return new Promise((resolvePort, reject) => {
    const server = createServer();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      if (address === null || typeof address === 'string') {
        server.close();
        reject(new Error('Could not resolve a free port'));
        return;
      }
      const { port } = address;
      server.close(() => resolvePort(port));
    });
  });
}

export async function startAppServer(): Promise<AppServer> {
  const stack = localStack();
  const port = await freePort();
  const origin = `http://127.0.0.1:${port}`;

  const child: ChildProcess = spawn(
    join(repoRoot, 'node_modules', '.bin', 'next'),
    ['dev', '--port', String(port), '--hostname', '127.0.0.1'],
    {
      cwd: repoRoot,
      env: {
        ...process.env,
        // Point the whole application at the LOCAL stack, overriding
        // `.env.local`. Without these three the suite would authenticate
        // against the hosted development project.
        NEXT_PUBLIC_SUPABASE_URL: stack.url,
        NEXT_PUBLIC_SUPABASE_ANON_KEY: stack.anonKey,
        SUPABASE_SERVICE_ROLE_KEY: stack.serviceRoleKey,
        NEXT_PUBLIC_SITE_URL: origin,
        NODE_ENV: 'development',
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  );

  // Captured rather than piped to the terminal: the environment above contains
  // the service-role key, and a crash dump that echoed the env would put it in
  // a CI log. Only surfaced if startup fails, and even then only the tail.
  let log = '';
  child.stdout?.on('data', (chunk: Buffer) => {
    log += chunk.toString();
  });
  child.stderr?.on('data', (chunk: Buffer) => {
    log += chunk.toString();
  });

  const stop = async () => {
    if (child.exitCode !== null || child.signalCode !== null) return;
    child.kill('SIGTERM');
    await new Promise((r) => setTimeout(r, 250));
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  };

  // Poll a public route until the dev server compiles and answers.
  const deadline = Date.now() + 90_000;
  for (;;) {
    if (Date.now() > deadline) {
      await stop();
      throw new Error(
        `The Next dev server did not become ready within 90s.\nLast output:\n${log.slice(-2000)}`,
      );
    }
    try {
      const response = await fetch(`${origin}/sign-in`, { redirect: 'manual' });
      if (response.status < 500) break;
    } catch {
      // Not listening yet.
    }
    await new Promise((r) => setTimeout(r, 400));
  }

  return { origin, stop };
}

// ---------------------------------------------------------------------------
// A cookie jar with the parts of the browser contract this suite depends on
// ---------------------------------------------------------------------------

export type ParsedCookie = {
  name: string;
  value: string;
  httpOnly: boolean;
  sameSite: string | null;
  secure: boolean;
  path: string | null;
  maxAge: number | null;
};

export function parseSetCookie(header: string): ParsedCookie {
  const [pair = '', ...attributes] = header.split(';');
  const eq = pair.indexOf('=');
  const flags = attributes.map((a) => a.trim());
  const attribute = (name: string): string | null => {
    const found = flags.find((f) => f.toLowerCase().startsWith(`${name}=`));
    return found ? found.slice(name.length + 1) : null;
  };

  const maxAge = attribute('max-age');

  return {
    name: pair.slice(0, eq),
    value: pair.slice(eq + 1),
    httpOnly: flags.some((f) => f.toLowerCase() === 'httponly'),
    secure: flags.some((f) => f.toLowerCase() === 'secure'),
    sameSite: attribute('samesite'),
    path: attribute('path'),
    maxAge: maxAge === null ? null : Number(maxAge),
  };
}

/**
 * The jar. Deliberately minimal and deliberately NOT a library: the assertions
 * in this suite are about which cookies were set and with which flags, so the
 * mechanics have to be visible rather than hidden behind an abstraction that
 * might normalise away the thing under test.
 */
export class CookieJar {
  private readonly cookies = new Map<string, ParsedCookie>();

  /** Every Set-Cookie the server sent, in order, across all requests. */
  readonly received: ParsedCookie[] = [];

  ingest(response: Response): void {
    for (const header of response.headers.getSetCookie()) {
      const cookie = parseSetCookie(header);
      if (!cookie.name) continue;
      this.received.push(cookie);
      // An expiry in the past, or an empty value, is a deletion.
      if (cookie.value === '' || cookie.maxAge === 0) {
        this.cookies.delete(cookie.name);
      } else {
        this.cookies.set(cookie.name, cookie);
      }
    }
  }

  header(): string {
    return [...this.cookies.values()].map((c) => `${c.name}=${c.value}`).join('; ');
  }

  names(): string[] {
    return [...this.cookies.keys()];
  }

  get size(): number {
    return this.cookies.size;
  }

  clear(): void {
    this.cookies.clear();
  }

  /** A snapshot that survives the jar being cleared — for the stale-session test. */
  snapshot(): string {
    return this.header();
  }
}

/**
 * `fetch` with the jar attached and redirects NOT followed, because the
 * redirect itself is what most of these tests are asserting.
 */
export async function request(
  server: AppServer,
  path: string,
  init: RequestInit & { jar?: CookieJar; cookieHeader?: string } = {},
): Promise<Response> {
  const { jar, cookieHeader, headers, ...rest } = init;
  const cookie = cookieHeader ?? jar?.header() ?? '';

  const response = await fetch(`${server.origin}${path}`, {
    ...rest,
    redirect: 'manual',
    headers: {
      ...(headers as Record<string, string> | undefined),
      ...(cookie ? { cookie } : {}),
    },
  });

  jar?.ingest(response);
  return response;
}

/** The `Location` header as a path + query, so assertions read like the route map. */
export function locationPath(response: Response): string {
  const location = response.headers.get('location');
  if (!location) return '';
  try {
    const url = new URL(location, 'http://placeholder.invalid');
    return `${url.pathname}${url.search}`;
  } catch {
    return location;
  }
}
