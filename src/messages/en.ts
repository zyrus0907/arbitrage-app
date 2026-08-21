/**
 * The only place user-facing copy lives (ARCHITECTURE.md §4.2, §13).
 *
 * Components read keys from here rather than embedding strings, so translation
 * later is a data exercise rather than a rewrite. No currency symbol, no date
 * format and no country name belongs in this file.
 */
export const messages = {
  app: {
    name: 'Arbitrage',
    tagline: 'Defensible numbers for retail arbitrage.',
  },
  /**
   * Development dashboard. Internal tooling, not product copy — this block is
   * removed with `src/components/dev/` and `src/lib/dev-dashboard/`.
   */
  dev: {
    badge: 'Dev',
    title: 'Arbitrage App',
    subtitle: 'Development Dashboard',
    backend: {
      connected: 'Backend connected',
      unavailable: 'Backend unavailable',
    },
    backendError: {
      title: 'The database did not answer.',
      body: 'Counts and reference data are unavailable for this request. Diagnostic detail is deliberately not shown here — check the server logs.',
    },
    tables: {
      heading: 'Tables',
      description: 'Live row counts, read server-side on every request.',
      markets: 'Markets',
      retailers: 'Retailers',
      retailerProducts: 'Retailer products',
      marketplaceProducts: 'Marketplace products',
      deals: 'Deals',
      creditPacks: 'Credit packs',
      creditPurchases: 'Credit purchases',
      profiles: 'Users / profiles',
    },
    lifecycle: {
      heading: 'Deal lifecycle',
      description: 'Counted from deals.status. A deal starts as a draft, may be published, and retirement is terminal.',
      draft: 'Draft',
      active: 'Active',
      retired: 'Retired',
    },
    currencies: {
      heading: 'Reference data',
      description: 'Minor-unit exponents come from the database, never from an assumed hundredth.',
      code: 'ISO code',
      name: 'Name',
      exponent: 'Minor unit exponent',
      empty: 'No currency rows in this database yet.',
      unavailable: 'Currency rows could not be read.',
    },
    system: {
      heading: 'System',
      database: 'Supabase database',
      databaseConnected: 'Connected',
      databaseUnavailable: 'Error',
      environment: 'Environment',
      environments: {
        development: 'Development',
        test: 'Test',
        production: 'Production',
      },
      types: 'Database types',
      typesAvailable: 'Available',
      typesUnavailable: 'Unavailable',
      credentials: 'Server credentials',
      credentialsConfigured: 'Configured',
      credentialsMissing: 'Missing',
    },
    footer:
      'Development tooling. Read-only, rendered on the server, and safe to remove — it is not part of the product interface.',
  },

  /** T10 — auth, onboarding, settings and account deletion. */
  auth: {
    signIn: {
      title: 'Sign in',
      subtitle: 'Welcome back.',
      submit: 'Sign in',
      submitting: 'Signing in…',
      noAccount: 'No account yet?',
      createOne: 'Create one',
      orMagicLink: 'Or get a sign-in link by email',
      magicLinkSubmit: 'Email me a link',
      magicLinkSubmitting: 'Sending…',
    },
    signUp: {
      title: 'Create your account',
      subtitle: 'You get five free credits to try the numbers out.',
      submit: 'Create account',
      submitting: 'Creating your account…',
      haveAccount: 'Already have an account?',
      signIn: 'Sign in',
    },
    checkEmail: {
      title: 'Check your email',
      body: 'If that address can be used, a link is on its way. Open it on this device to continue.',
      back: 'Back to sign in',
    },
    fields: {
      email: 'Email address',
      password: 'Password',
      passwordHint: 'At least 8 characters.',
    },
    signOut: 'Sign out',
    errors: {
      invalidInput: 'Check the details and try again.',
      invalidCredentials: 'That email and password did not match an account.',
      linkFailed: 'That link has expired or has already been used. Request a new one.',
      // T11/F9. Deliberately says nothing about whether the address already has
      // an account: the signup form must not become the enumeration oracle that
      // the sign-in form was carefully built not to be.
      signUpFailed: 'We could not complete that sign-up. Check the details and try again.',
    },
  },

  onboarding: {
    title: 'Set up your account',
    subtitle: 'Six quick questions. Your answers change every profit figure we show you, so they are worth thirty seconds.',
    submit: 'Finish setup',
    submitting: 'Saving…',
    steps: {
      market: {
        legend: '1. Where do you buy and sell?',
        hint: 'This sets your currency, your tax rules and the marketplace fees we apply.',
        label: 'Market',
        placeholder: 'Select a market',
        countryLabel: 'Country',
      },
      tax: {
        legend: '2. Tax registration',
        registeredLabel: 'I am registered for the tax scheme in my country',
        // Deliberately regime-neutral: the concrete consequence is rendered
        // from the resolved market's tax regime, never hard-coded to VAT.
        hint: 'We default to not registered, which is the more cautious assumption — it treats tax on your costs as money you do not get back, so estimated profit is lower rather than higher.',
        schemeLabel: 'Scheme',
        registrationCountryLabel: 'Registered in',
      },
      fulfilment: {
        legend: '3. How will you fulfil orders?',
        label: 'Fulfilment',
      },
      budget: {
        legend: '4. Working budget',
        hint: 'Roughly how much you can put into stock at once. Used to size recommendations, never shared.',
      },
      prep: {
        legend: '5. Prep cost per unit',
        hint: 'Labels, poly bags, your time. Leave at zero if you are not sure yet.',
      },
      shipping: {
        legend: '6. Inbound shipping per unit',
        hint: 'What it costs you to get one unit to the marketplace.',
      },
    },
    fulfilmentOptions: {
      marketplace_fulfilled: 'Fulfilled by the marketplace',
      seller_fulfilled: 'Fulfilled by me',
    },
    taxSchemeOptions: {
      standard: 'Standard',
      simplified: 'Simplified',
    },
    noMarket: {
      title: 'We are not live in your country yet',
      body: 'Rather than show you another country’s prices — which would be confidently wrong — we will hold your place and tell you when we open.',
      submit: 'Join the waitlist',
    },
  },

  waitlist: {
    title: 'You are on the list',
    body: 'We are not operating in your country yet. Your account is set up and your credits are waiting; we will email you when a market opens near you.',
    changeCountry: 'Choose a different country',
  },

  settings: {
    title: 'Settings',
    subtitle: 'Your market, tax status and cost assumptions.',
    save: 'Save changes',
    saving: 'Saving…',
    saved: 'Saved.',
    creditsLabel: 'Credit balance',
    dangerZone: {
      title: 'Delete your account',
      body: 'This removes your profile, your unlocks, your watchlist, your purchase records and your sign-in. It cannot be undone.',
      retained:
        'Your credit ledger and any credit purchases are kept as accounting records, with nothing left in them that identifies you. We keep them because a payment can be reversed after an account closes, and because we have to be able to reconcile what was bought.',
      confirmLabel: 'Type DELETE to confirm',
      confirmWord: 'DELETE',
      submit: 'Delete my account permanently',
      submitting: 'Deleting…',
      error: 'We could not complete the deletion. Nothing has been left half-done — try again.',
    },
  },

  feed: {
    placeholderTitle: 'Your feed is being built',
    placeholderBody:
      'Deal supply and the feed itself arrive in a later task. Your account, market and credits are set up and ready for them.',
  },
} as const;

export type Messages = typeof messages;
