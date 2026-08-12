import { NextResponse, type NextRequest } from 'next/server';

import { createClient } from '@/lib/supabase/server';

/**
 * Sign out (F1).
 *
 * **POST only.** A GET sign-out is a CSRF hole and a prefetch hazard in equal
 * measure: any third-party page could log the user out with an `<img>` tag, and
 * a link prefetcher could do it by accident. The nav renders a form that posts
 * here.
 *
 * `signOut()` revokes the refresh token server-side and clears the auth cookies
 * through the same cookie jar that set them, so the browser is left with no
 * credential — not merely a credential it has been asked to stop using.
 */
export async function POST(request: NextRequest) {
  const supabase = await createClient();

  // Only meaningful with a session; without one this is already the end state.
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (user) await supabase.auth.signOut();

  // 303 so the browser follows with GET rather than replaying the POST.
  return NextResponse.redirect(new URL('/', request.nextUrl.origin), { status: 303 });
}
