/**
 * Redirect-target validation.
 *
 * Two places in T10 take a destination from something the user controls: the
 * `?next=` parameter that carries an interrupted request through sign-in
 * (AC1.3), and the auth callback that Supabase returns the browser to. Both are
 * classic open-redirect sites — an attacker who can choose where sign-in sends
 * you can land the victim on a look-alike page immediately after a genuine,
 * successful authentication, which is the moment they are least suspicious.
 *
 * The rule here is deliberately the strictest one that still does the job:
 * **same-origin, path-absolute, and nothing else.** No absolute URLs, not even
 * to our own host — accepting `https://our-site/...` means parsing and
 * comparing origins, and every open redirect in the wild is a bug in exactly
 * that comparison. A path can be checked with string rules that have no
 * ambiguity to exploit.
 *
 * Rejected, with the attack each rule stops:
 *
 *   - `https://evil.test/x`  — absolute URL, any scheme.
 *   - `//evil.test/x`        — protocol-relative; browsers treat it as absolute.
 *   - `/\evil.test/x`        — backslash; several browsers normalise `\` to `/`
 *                              before resolving, so `/\` behaves like `//`.
 *   - `\\evil.test`          — the same trick without a leading slash.
 *   - `javascript:...`, `data:...` — scheme-bearing, caught by the leading-`/`
 *                              requirement, but also by the explicit scheme test
 *                              so the reason is unambiguous in a test failure.
 *   - anything containing a control character, including the encoded `%0A` /
 *     `%0D` that survive into a `Location` header as a response split.
 *   - a target that is itself an auth route, which would loop or bounce a user
 *     straight back out of the session they just established.
 */
import { SIGN_IN_PATH } from './routes';

/** Paths a post-authentication redirect must never resolve to. */
const NEVER_RETURN_TO = ['/sign-in', '/sign-up', '/auth/callback', '/auth/sign-out'];

/** Matches `scheme:` at the start of a string, per RFC 3986. */
const HAS_SCHEME = /^[a-z][a-z0-9+.-]*:/i;

/** C0 and C1 control characters, in decoded form. */
const HAS_CONTROL_CHAR = /[\u0000-\u001f\u007f-\u009f]/;

/**
 * Returns `candidate` when it is a safe same-origin path, and `fallback`
 * otherwise. Never throws and never returns anything it was not given.
 */
export function safeRedirectPath(
  candidate: string | null | undefined,
  fallback: string,
): string {
  if (typeof candidate !== 'string' || candidate.length === 0) return fallback;

  // A `next` value arrives percent-encoded once, decoded by the URL parser.
  // Decoding again is what catches `%252f%252f` style double-encoding, where a
  // downstream consumer performs the second decode we did not expect.
  let value = candidate;
  for (let pass = 0; pass < 2; pass += 1) {
    if (HAS_CONTROL_CHAR.test(value)) return fallback;
    try {
      const decoded = decodeURIComponent(value);
      if (decoded === value) break;
      value = decoded;
    } catch {
      // Malformed percent-encoding. Nothing legitimate produces it.
      return fallback;
    }
  }

  if (HAS_CONTROL_CHAR.test(value)) return fallback;
  if (HAS_SCHEME.test(value)) return fallback;

  // Path-absolute, single leading slash. `//` and `/\` are both absolute to a
  // browser; `\` anywhere is rejected rather than normalised, because deciding
  // what it "meant" is the ambiguity being avoided.
  if (!value.startsWith('/')) return fallback;
  if (value.startsWith('//')) return fallback;
  if (value.includes('\\')) return fallback;

  const pathname = value.split(/[?#]/, 1)[0] ?? '';
  if (NEVER_RETURN_TO.includes(pathname)) return fallback;

  // The ORIGINAL is returned, not the decoded form. Decoding is how the checks
  // above see through `%2f%2f`; returning the decoded string would change the
  // destination, so `/deal/a%20b` — a legitimate path containing an encoded
  // space — would silently become `/deal/a b`.
  return candidate;
}

/**
 * Builds the sign-in URL for an interrupted request, carrying the intended
 * route so the user is returned to it afterwards (AC1.3).
 *
 * The `next` value is validated on the way IN as well as on the way out. It
 * costs nothing and it means a malformed target is dropped at the point it is
 * created, rather than stored in a URL a user might share.
 */
export function signInUrlFor(intendedPath: string): string {
  const next = safeRedirectPath(intendedPath, '');
  if (!next) return SIGN_IN_PATH;
  return `${SIGN_IN_PATH}?next=${encodeURIComponent(next)}`;
}
