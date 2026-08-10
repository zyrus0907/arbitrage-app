# `src/components/dev/`

Presentation for the **development dashboard** at `/`. Internal tooling, not
product UI, and deliberately isolated so it can be deleted in one step — see
`src/lib/dev-dashboard/README.md` for the full removal list.

## Rules

- Pure presentation. These components take a snapshot and render it: no data
  access, no `'use client'`, no environment lookup, no arithmetic beyond
  formatting a count at the render boundary.
- Copy comes from the `dev` block of `src/messages/en.ts`, like every other
  component (§4.2).
- Do not reuse these in product surfaces. `ui/`, `deals/`, `market/`,
  `credits/`, `scan/` and `layout/` own that, and the product's visual language
  is decided by the tasks that build it.
