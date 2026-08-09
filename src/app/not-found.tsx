export default function NotFound() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-md flex-col justify-center gap-3 p-6">
      <h1 className="text-2xl font-semibold tracking-tight">Not found</h1>
      <p className="text-sm text-neutral-600 dark:text-neutral-400">
        That page does not exist.
      </p>
    </main>
  );
}
