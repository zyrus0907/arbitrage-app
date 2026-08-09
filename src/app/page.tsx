import { messages } from '@/messages/en';

export default function HomePage() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-md flex-col justify-center gap-3 p-6">
      <h1 className="text-2xl font-semibold tracking-tight">{messages.home.heading}</h1>
      <p className="text-sm text-neutral-600 dark:text-neutral-400">{messages.home.body}</p>
    </main>
  );
}
