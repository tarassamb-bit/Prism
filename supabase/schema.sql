-- Prism account stats. Run once in Supabase → SQL Editor.
-- One row per finished export from the Mac app. Row Level Security keeps every user to their own rows.

create table if not exists public.exports (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  created_at  timestamptz not null default now(),
  short_count integer not null check (short_count between 1 and 100),
  seconds     double precision not null check (seconds >= 0 and seconds < 100000),
  quality     text not null check (quality in ('full', 'compact', 'small'))
);

alter table public.exports enable row level security;

drop policy if exists "Read own exports" on public.exports;
create policy "Read own exports" on public.exports
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "Add own exports" on public.exports;
create policy "Add own exports" on public.exports
  for insert to authenticated with check (user_id = auth.uid());

create index if not exists exports_user_created on public.exports (user_id, created_at desc);

-- Paddle subscriptions, written only by the webhook (api/paddle-webhook.js) with the service role key.
-- Each row belongs to the Supabase user whose ID was passed as customData at checkout.
create table if not exists public.subscriptions (
  id               text primary key,
  user_id          uuid not null references auth.users (id) on delete cascade,
  customer_id      text not null,
  price_id         text,
  status           text not null,
  next_billed_at   timestamptz,
  scheduled_change jsonb,
  event_at         timestamptz not null
);

alter table public.subscriptions enable row level security;

drop policy if exists "Read own subscriptions" on public.subscriptions;
create policy "Read own subscriptions" on public.subscriptions
  for select to authenticated using (user_id = auth.uid());

create index if not exists subscriptions_user on public.subscriptions (user_id);
