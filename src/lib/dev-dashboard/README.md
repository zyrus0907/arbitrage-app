# `src/lib/dev-dashboard/`

Server-side data collection for the **development dashboard** at `/`.

Developer tooling, not product UI. Delete this directory, `src/components/dev/`,
the `dev` block in `src/messages/en.ts` and `tests/unit/dev-dashboard/`, then
replace `src/app/page.tsx`, and nothing else in the application is affected.

## Rules

- `snapshot.ts` is the only module here that touches the environment or builds a
  client, and it is `server-only`. Everything else takes its client as an
  argument, which is what makes the read path testable without a database.
- Reads use the **admin client** because `anon` and `authenticated` hold no table
  privileges (ADR-004). That is the correct posture and this page does not
  change it: no grant, policy or migration exists to support this dashboard.
- The snapshot is what reaches the browser. It carries aggregate counts, public
  reference rows and environment booleans — never a credential, a URL, a
  connection string or a provider error message.
- Failures resolve to `null`, never to a thrown error or a substituted number. A
  page that cannot reach the database still renders and says so.
