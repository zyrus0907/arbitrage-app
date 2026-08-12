/**
 * Shell for the sign-in, sign-up and check-email screens.
 *
 * A separate layout from `(app)` on purpose: these pages must render for a
 * visitor with no session, so they carry no navigation, no balance and nothing
 * that would need a user to exist.
 */
export default function AuthLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <main className="mx-auto flex min-h-dvh w-full max-w-md flex-col justify-center px-6 py-12">
      {children}
    </main>
  );
}
