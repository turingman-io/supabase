# Running Supabase Studio locally (self-hosted mode)

Studio (`apps/studio`) runs from this checkout against a local Supabase stack, the same
way the self-hosted Studio E2E suite runs it.

## Requirements

- Docker with at least 4 vCPU and 8 GB RAM
- Node.js 24 and pnpm 11.13 (the `packageManager` in the root `package.json`)
- curl

## Start

1. `pnpm install`
2. `pnpm e2e:setup:selfhosted` and keep it running. It:
   - starts the local backend with this repo's Supabase CLI
     (`supabase start --exclude studio,mailpit --workdir ./e2e/studio`)
   - writes `keys.json` and `apps/studio/.env.test`, then builds Studio from this checkout
   - serves Studio at http://localhost:8082 (self-hosted Studio has no login)
3. In a second terminal: `bash scripts/demo/seed.sh`

## Demo data

`scripts/demo/seed.sh` loads a small storefront into the local stack:

- tables in `public` and `analytics`: customers, products, warehouses, stock levels
  (composite key), orders, order items (composite key), support tickets, page views;
  generated columns, enums, a view, a materialized view, functions and triggers
- RLS policies, a `reporting_reader` role and the realtime publication
- cron jobs (pg_cron, pg_net), queues (pgmq) and vault secrets
- storage buckets `avatars`, `product-images` and `invoices`, with files
- 9 auth users with password `password123`, linked to customers by email
  (`customer007@example.com` has not confirmed their email)

Running it again is safe: it stops if the data is already loaded.

## Conventions

- Timezone UTC, locale en-US.
- Nothing beyond localhost is needed at runtime; outbound network access is blocked.
