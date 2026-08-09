'use client';

export default function GlobalError({ reset }: { error: Error; reset: () => void }) {
  return (
    <main className="mx-auto flex min-h-dvh max-w-md flex-col justify-center gap-3 p-6">
      <h1 className="text-2xl font-semibold tracking-tight">Something went wrong</h1>
      <button
        type="button"
        onClick={reset}
        className="self-start rounded border px-3 py-1.5 text-sm"
      >
        Try again
      </button>
    </main>
  );
}
