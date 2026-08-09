import type { Metadata } from 'next';
// Side-effect import: validates the environment at boot, so a misconfigured
// deployment fails immediately and loudly rather than at some later request.
import '@/lib/env';
import { messages } from '@/messages/en';
import './globals.css';

export const metadata: Metadata = {
  title: messages.app.name,
  description: messages.app.tagline,
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body className="min-h-dvh">{children}</body>
    </html>
  );
}
