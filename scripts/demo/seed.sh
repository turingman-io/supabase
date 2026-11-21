#!/usr/bin/env bash
# Loads the demo dataset (scripts/demo/seed.sql) into the local stack started by
# `pnpm e2e:setup:selfhosted` or `pnpm e2e:setup:cli`: auth users, tables and data,
# policies, cron jobs, queues, vault secrets, realtime and storage files.
#
# Usage: bash scripts/demo/seed.sh     (needs docker, curl and node; safe to re-run)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

WORKDIR=./e2e/studio
DB_CONTAINER="${DB_CONTAINER:-supabase_db_studio}"
DEMO_PASSWORD="${DEMO_PASSWORD:-password123}"

if [ ! -f keys.json ]; then
  pnpm exec supabase status --output json --workdir "$WORKDIR" > keys.json
fi
API_URL="$(node -p 'require("./keys.json").API_URL')"
SERVICE_KEY="$(node -p 'require("./keys.json").SERVICE_ROLE_KEY')"

psql_db() {
  docker exec -i -e PGPASSWORD=postgres "$DB_CONTAINER" \
    psql -h 127.0.0.1 -U postgres -d postgres -v ON_ERROR_STOP=1 -q "$@"
}

if [ "$(psql_db -tAc "select to_regclass('public.customers') is not null")" = "t" ]; then
  echo "Demo data is already loaded (public.customers exists); nothing to do."
  exit 0
fi

auth_headers=(-H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY")

create_user() { # email full_name email_confirmed
  local body code
  body="$(printf '{"email":"%s","password":"%s","email_confirm":%s,"user_metadata":{"full_name":"%s"}}' \
    "$1" "$DEMO_PASSWORD" "$3" "$2")"
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API_URL/auth/v1/admin/users" "${auth_headers[@]}" \
    -H "Content-Type: application/json" -d "$body")"
  case "$code" in
    200 | 201) ;;
    422) echo "  $1 already exists" ;;
    *) echo "Creating $1 failed with HTTP $code" >&2; return 1 ;;
  esac
}

echo "Creating auth users..."
create_user customer001@example.com "Grace Hopper" true
create_user customer002@example.com "Linus Torvalds" true
create_user customer003@example.com "Margaret Hamilton" true
create_user customer004@example.com "Alan Turing" true
create_user customer005@example.com "Barbara Liskov" true
create_user customer006@example.com "Ken Thompson" true
create_user customer007@example.com "Radia Perlman" false
create_user jordan.lee@example.com "Jordan Lee" true
create_user priya.shah@example.com "Priya Shah" true

echo "Loading tables, policies, cron jobs, queues and vault secrets..."
psql_db < scripts/demo/seed.sql

upload() { # bucket object-path content-type content
  curl -fsS -o /dev/null -X POST "$API_URL/storage/v1/object/$1/$2" "${auth_headers[@]}" \
    -H "Content-Type: $3" -H "x-upsert: true" --data-binary "$4"
}

svg() { # label background
  printf '<svg xmlns="http://www.w3.org/2000/svg" width="160" height="160" viewBox="0 0 160 160"><rect width="160" height="160" rx="24" fill="%s"/><text x="80" y="94" font-family="sans-serif" font-size="44" text-anchor="middle" fill="#ffffff">%s</text></svg>' "$2" "$1"
}

echo "Uploading storage files..."
colors=("#3b82f6" "#10b981" "#f59e0b" "#ef4444" "#8b5cf6" "#ec4899")
i=0
while IFS='|' read -r user_id email initials; do
  [ -n "$user_id" ] || continue
  upload avatars "$user_id/avatar.svg" image/svg+xml "$(svg "$initials" "${colors[$((i % 6))]}")"
  upload invoices "$user_id/INV-2026-$(printf '%04d' $((i + 1))).txt" text/plain \
    "$(printf 'Invoice INV-2026-%04d\nCustomer: %s\nAmount due: %s.00 USD\n' $((i + 1)) "$email" $((40 + i * 15)))"
  i=$((i + 1))
done < <(psql_db -tA -F '|' -c "select u.id, u.email, upper(left(split_part(c.full_name, ' ', 1), 1) || left(split_part(c.full_name, ' ', 2), 1))
  from auth.users u join public.customers c on c.user_id = u.id
  where u.email_confirmed_at is not null order by u.email")

for n in $(seq 1 12); do
  sku="$(printf 'SKU-%04d' "$n")"
  upload product-images "catalog/2026.11/$sku.svg" image/svg+xml "$(svg "$n" "${colors[$((n % 6))]}")"
done
upload product-images "catalog/archive/2025/SKU-0001.svg" image/svg+xml "$(svg "1" "#64748b")"
upload product-images "banners/home.hero.v2.svg" image/svg+xml "$(svg "Sale" "#0f172a")"

for month in 09 10; do
  csv="$(psql_db -c "copy (
      select order_id, full_name, status, currency, placed_at, item_count, total
      from public.order_summaries
      where placed_at >= timestamptz '2026-$month-01 00:00:00+00'
        and placed_at < timestamptz '2026-$month-01 00:00:00+00' + interval '1 month'
      order by order_id
    ) to stdout with (format csv, header)")"
  upload invoices "exports/2026.$month/orders.csv" text/csv "$csv"
done

psql_db -tA -c "select format('Demo data loaded: %s customers, %s products, %s orders, %s auth users, %s storage objects.',
  (select count(*) from public.customers), (select count(*) from public.products), (select count(*) from public.orders),
  (select count(*) from auth.users), (select count(*) from storage.objects))"
