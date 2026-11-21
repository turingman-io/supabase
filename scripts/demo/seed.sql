-- Demo dataset for local Studio development: a small storefront with customers,
-- products, stock, orders, support tickets and page analytics, plus the database
-- features Studio manages (RLS policies, roles, triggers, functions, views, cron
-- jobs, queues, vault secrets, realtime and storage).
--
-- Loaded by scripts/demo/seed.sh after the auth users exist. Values are fixed
-- (no random()), so every load produces the same rows and ids.

begin;

-- Extensions ---------------------------------------------------------------
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;
create extension if not exists pgmq;

-- Types --------------------------------------------------------------------
create type public.order_status as enum ('pending', 'paid', 'shipped', 'delivered', 'cancelled', 'refunded');
create type public.ticket_priority as enum ('low', 'normal', 'high', 'urgent');

-- Customers ----------------------------------------------------------------
create table public.customers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users (id) on delete set null,
  email text not null unique,
  full_name text not null,
  country text not null,
  marketing_opt_in boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
comment on table public.customers is 'People who placed at least one order.';

insert into public.customers (id, email, full_name, country, marketing_opt_in, metadata, created_at)
select
  md5('customer-' || i)::uuid,
  format('customer%s@example.com', lpad(i::text, 3, '0')),
  (array['Ada', 'Grace', 'Linus', 'Margaret', 'Alan', 'Barbara', 'Ken', 'Radia', 'Tim', 'Frances'])[1 + (i % 10)]
    || ' ' ||
  (array['Lovelace', 'Hopper', 'Torvalds', 'Hamilton', 'Turing', 'Liskov', 'Thompson', 'Perlman', 'Berners-Lee', 'Allen', 'Ritchie', 'Knuth'])[1 + (i % 12)],
  (array['US', 'GB', 'DE', 'FR', 'JP', 'BR', 'IN', 'AU', 'CA', 'NL'])[1 + (i * 7 % 10)],
  i % 3 = 0,
  jsonb_build_object(
    'tier', (array['free', 'pro', 'team'])[1 + (i % 3)],
    'source', (array['ads', 'referral', 'organic', 'partner'])[1 + (i % 4)]
  ),
  timestamptz '2026-06-01 08:00:00+00' + i * interval '2 days 3 hours'
from generate_series(1, 60) as i;

-- Products -----------------------------------------------------------------
create table public.products (
  id bigint generated always as identity primary key,
  sku text not null unique,
  name text not null,
  description text,
  category text not null,
  price numeric(10, 2) not null check (price >= 0),
  tax_rate numeric(4, 3) not null default 0.200,
  price_with_tax numeric(10, 2) generated always as (round(price * (1 + tax_rate), 2)) stored,
  is_active boolean not null default true,
  tags text[] not null default '{}',
  search tsvector generated always as (to_tsvector('english', name || ' ' || coalesce(description, ''))) stored,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index products_search_idx on public.products using gin (search);
create index products_category_idx on public.products (category);

insert into public.products (sku, name, description, category, price, tax_rate, is_active, tags, created_at, updated_at)
select
  format('SKU-%s', lpad(i::text, 4, '0')),
  (array['Desk Lamp', 'Notebook', 'Backpack', 'Water Bottle', 'Headphones', 'Keyboard', 'Mouse Pad', 'Monitor Stand', 'Coffee Mug', 'Phone Case'])[1 + (i % 10)]
    || ' ' || (array['Classic', 'Pro', 'Mini', 'Plus', 'Max'])[1 + (i % 5)],
  case when i % 4 = 0 then null else 'Durable everyday item, batch ' || (i % 7 + 1) end,
  (array['office', 'travel', 'audio', 'kitchen', 'accessories'])[1 + (i % 5)],
  round((5 + (i * 37 % 200) + (i % 100) / 100.0)::numeric, 2),
  case when i % 5 = 0 then 0.070 else 0.200 end,
  i % 9 <> 0,
  array[(array['new', 'sale', 'eco', 'bestseller'])[1 + (i % 4)]],
  timestamptz '2026-05-01 10:00:00+00' + i * interval '1 day',
  timestamptz '2026-05-01 13:00:00+00' + i * interval '1 day'
from generate_series(1, 40) as i;

-- Warehouses and stock (composite primary key) ------------------------------
create table public.warehouses (
  id smallint generated always as identity primary key,
  code text not null unique,
  city text not null
);
insert into public.warehouses (code, city) values ('AMS1', 'Amsterdam'), ('SFO2', 'San Francisco'), ('SIN1', 'Singapore');

create table public.stock_levels (
  warehouse_id smallint not null references public.warehouses (id) on delete cascade,
  product_id bigint not null references public.products (id) on delete cascade,
  quantity integer not null default 0 check (quantity >= 0),
  reorder_point integer not null default 10,
  updated_at timestamptz not null default now(),
  primary key (warehouse_id, product_id)
);
insert into public.stock_levels (warehouse_id, product_id, quantity, reorder_point, updated_at)
select w.id, p.id, ((p.id * 13 + w.id * 7) % 120)::integer, 10 + (p.id % 3)::integer * 5,
       timestamptz '2026-11-01 06:00:00+00' + p.id * interval '1 hour'
from public.warehouses w
cross join public.products p
where (p.id + w.id) % 4 <> 0;

-- Orders and order items (composite primary key) ----------------------------
create table public.orders (
  id bigint generated always as identity primary key,
  customer_id uuid not null references public.customers (id) on delete restrict,
  status public.order_status not null default 'pending',
  currency char(3) not null default 'USD',
  shipping_address jsonb,
  notes text,
  placed_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index orders_customer_id_idx on public.orders (customer_id);
create index orders_status_placed_at_idx on public.orders (status, placed_at desc);

insert into public.orders (customer_id, status, currency, shipping_address, notes, placed_at, updated_at)
select
  md5('customer-' || (1 + (i * 17 % 60)))::uuid,
  (array['pending', 'paid', 'shipped', 'delivered', 'delivered', 'delivered', 'cancelled', 'refunded'])[1 + (i % 8)]::public.order_status,
  (array['USD', 'EUR', 'GBP'])[1 + (i % 3)],
  jsonb_build_object(
    'line1', (100 + i) || ' Market Street',
    'city', (array['Amsterdam', 'Austin', 'Berlin', 'Lisbon', 'Osaka'])[1 + (i % 5)],
    'postal_code', lpad((i * 97 % 99999)::text, 5, '0')
  ),
  case when i % 6 = 0 then 'Leave at the front desk' end,
  timestamptz '2026-08-01 12:00:00+00' + i * interval '9 hours',
  timestamptz '2026-08-01 14:00:00+00' + i * interval '9 hours'
from generate_series(1, 240) as i;

create table public.order_items (
  order_id bigint not null references public.orders (id) on delete cascade,
  product_id bigint not null references public.products (id) on delete restrict,
  quantity integer not null check (quantity > 0),
  unit_price numeric(10, 2) not null,
  discount numeric(4, 3) not null default 0,
  line_total numeric(12, 2) generated always as (round(quantity * unit_price * (1 - discount), 2)) stored,
  primary key (order_id, product_id)
);
insert into public.order_items (order_id, product_id, quantity, unit_price, discount)
select o.id, item.product_id, (1 + (o.id + item.n) % 4)::integer, p.price,
       case when (o.id + item.n) % 5 = 0 then 0.100 else 0 end
from public.orders o
cross join lateral (
  select 1 + ((o.id * 7 + n * 11) % 40) as product_id, n
  from generate_series(1, 1 + (o.id % 3)::integer) as n
) as item
join public.products p on p.id = item.product_id;

-- Support tickets ----------------------------------------------------------
create table public.support_tickets (
  id bigint generated always as identity primary key,
  customer_id uuid references public.customers (id) on delete set null,
  order_id bigint references public.orders (id) on delete set null,
  subject text not null,
  body text not null,
  priority public.ticket_priority not null default 'normal',
  status text not null default 'open' check (status in ('open', 'pending', 'resolved', 'closed')),
  assignee uuid references auth.users (id) on delete set null,
  tags text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
insert into public.support_tickets (customer_id, order_id, subject, body, priority, status, tags, created_at, updated_at)
select
  md5('customer-' || (1 + (i * 11 % 60)))::uuid,
  case when i % 3 = 0 then null else 1 + (i * 13 % 240) end,
  (array['Where is my order?', 'Item arrived damaged', 'Wrong size', 'Refund request', 'Change shipping address', 'Invoice copy'])[1 + (i % 6)],
  'Hi, ' || (array['my package has not arrived yet.', 'the lid was cracked on arrival.', 'I would like to exchange it.', 'please refund my last order.', 'I moved last week.', 'I need an invoice for my company.'])[1 + (i % 6)],
  (array['low', 'normal', 'normal', 'high', 'urgent'])[1 + (i % 5)]::public.ticket_priority,
  (array['open', 'pending', 'resolved', 'closed'])[1 + (i % 4)],
  array[(array['shipping', 'billing', 'returns'])[1 + (i % 3)]],
  timestamptz '2026-09-01 09:30:00+00' + i * interval '13 hours',
  timestamptz '2026-09-01 11:00:00+00' + i * interval '13 hours'
from generate_series(1, 80) as i;

-- Analytics ----------------------------------------------------------------
create schema if not exists analytics;

create table analytics.page_views (
  id bigint generated always as identity primary key,
  path text not null,
  referrer text,
  customer_id uuid references public.customers (id) on delete set null,
  duration_ms integer,
  viewed_at timestamptz not null
);
create index page_views_viewed_at_idx on analytics.page_views (viewed_at desc);

insert into analytics.page_views (path, referrer, customer_id, duration_ms, viewed_at)
select
  (array['/', '/products', '/products/SKU-0007', '/cart', '/checkout', '/account', '/help'])[1 + (i % 7)],
  (array[null, 'https://www.google.com/', 'https://news.ycombinator.com/', 'https://twitter.com/'])[1 + (i % 4)],
  case when i % 5 = 0 then null else md5('customer-' || (1 + (i % 60)))::uuid end,
  200 + (i * 53 % 9000),
  timestamptz '2026-10-01 00:00:00+00' + i * interval '29 minutes'
from generate_series(1, 1500) as i;

-- Views and functions ------------------------------------------------------
create view public.order_summaries with (security_invoker = true) as
select o.id as order_id, o.customer_id, c.full_name, o.status, o.currency, o.placed_at,
       count(oi.product_id) as item_count, coalesce(sum(oi.line_total), 0) as total
from public.orders o
join public.customers c on c.id = o.customer_id
left join public.order_items oi on oi.order_id = o.id
group by o.id, c.full_name;

create materialized view analytics.daily_revenue as
select date_trunc('day', o.placed_at) as day, o.currency, sum(oi.line_total) as revenue, count(distinct o.id) as orders
from public.orders o
join public.order_items oi on oi.order_id = o.id
where o.status in ('paid', 'shipped', 'delivered')
group by 1, 2;

create function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger products_set_updated_at before update on public.products
  for each row execute function public.set_updated_at();
create trigger orders_set_updated_at before update on public.orders
  for each row execute function public.set_updated_at();
create trigger support_tickets_set_updated_at before update on public.support_tickets
  for each row execute function public.set_updated_at();

create function public.low_stock(threshold integer default 10)
returns table (warehouse text, sku text, quantity integer)
language sql
stable
as $$
  select w.code, p.sku, s.quantity
  from public.stock_levels s
  join public.warehouses w on w.id = s.warehouse_id
  join public.products p on p.id = s.product_id
  where s.quantity < threshold
  order by s.quantity, p.sku;
$$;

-- Row level security -------------------------------------------------------
alter table public.products enable row level security;
alter table public.customers enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.support_tickets enable row level security;

create policy "Active products are visible to everyone" on public.products
  for select using (is_active);
create policy "Customers can view their own profile" on public.customers
  for select to authenticated using ((select auth.uid()) = user_id);
create policy "Customers can update their own profile" on public.customers
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "Customers can view their own orders" on public.orders
  for select to authenticated
  using (customer_id in (select id from public.customers where user_id = (select auth.uid())));
create policy "Customers can view items of their orders" on public.order_items
  for select to authenticated
  using (order_id in (
    select o.id from public.orders o join public.customers c on c.id = o.customer_id
    where c.user_id = (select auth.uid())
  ));
create policy "Customers can open tickets" on public.support_tickets
  for insert to authenticated
  with check (customer_id in (select id from public.customers where user_id = (select auth.uid())));
create policy "Assignees can update their tickets" on public.support_tickets
  for update to authenticated using (assignee = (select auth.uid()));

-- Roles and grants ---------------------------------------------------------
create role reporting_reader nologin;
grant usage on schema public, analytics to reporting_reader;
grant select on all tables in schema analytics to reporting_reader;
grant select on public.order_summaries to reporting_reader;

-- Realtime -----------------------------------------------------------------
alter publication supabase_realtime add table public.orders, public.support_tickets;

-- Link auth users created by seed.sh ---------------------------------------
update public.customers c set user_id = u.id from auth.users u where u.email = c.email;
update public.support_tickets t
set assignee = (select id from auth.users where email = case when t.id % 2 = 0 then 'jordan.lee@example.com' else 'priya.shah@example.com' end)
where t.status in ('pending', 'resolved');

-- Cron jobs ----------------------------------------------------------------
select cron.schedule('refresh-daily-revenue', '15 2 * * *', $$refresh materialized view analytics.daily_revenue$$);
select cron.schedule('purge-old-page-views', '0 3 * * 0', $$delete from analytics.page_views where viewed_at < now() - interval '180 days'$$);
select cron.schedule('notify-low-stock', '0 6 * * *', $$
  select net.http_post(
    url := 'http://localhost:54321/functions/v1/low-stock-alert',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := jsonb_build_object('items', (select count(*) from public.low_stock(5)))
  )
$$);

-- Queues -------------------------------------------------------------------
select pgmq.create('order_events');
select pgmq.create('email_outbox');
select pgmq.send('order_events', jsonb_build_object('order_id', i, 'event', 'order.paid')) from generate_series(1, 12) as i;
select pgmq.send('email_outbox', jsonb_build_object('to', format('customer%s@example.com', lpad(i::text, 3, '0')), 'template', 'shipping_update'))
from generate_series(1, 5) as i;

-- Vault --------------------------------------------------------------------
select vault.create_secret('local-webhook-signing-secret-4f1c', 'payments_webhook_secret', 'Signing secret for payment provider webhooks');
select vault.create_secret('local-mail-api-key-77ad', 'mail_api_key', 'Transactional email API key');

-- Storage buckets and policies ---------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('avatars', 'avatars', true, 1048576, array['image/png', 'image/jpeg', 'image/svg+xml']),
  ('product-images', 'product-images', true, 5242880, null),
  ('invoices', 'invoices', false, 10485760, array['application/pdf', 'text/csv', 'text/plain']);

create policy "Avatar images are publicly accessible" on storage.objects
  for select using (bucket_id = 'avatars');
create policy "Users can upload their own avatar" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "Customers can read their own invoices" on storage.objects
  for select to authenticated
  using (bucket_id = 'invoices' and (storage.foldername(name))[1] = (select auth.uid())::text);

commit;
