import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import HomePage from '@/app/page';
import { messages } from '@/messages/en';

describe('home route', () => {
  it('renders its heading', () => {
    render(<HomePage />);
    expect(
      screen.getByRole('heading', { level: 1, name: messages.home.heading }),
    ).toBeInTheDocument();
  });

  it('renders copy from the message catalogue', () => {
    render(<HomePage />);
    expect(screen.getByText(messages.home.body)).toBeInTheDocument();
  });
});
