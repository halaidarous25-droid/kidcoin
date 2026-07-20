-- ═══════════════════════════════════════════════════════════════════════
--  KidCoins — بنك العائلة  |  Production Database Schema (Supabase / PostgreSQL)
--  Multi-tenant family banking platform with parent + child authentication.
--
--  Run this ONCE in the Supabase SQL Editor (Dashboard → SQL Editor → New query).
--  Idempotent-ish: safe to re-run in a fresh project. For existing projects,
--  review before re-running (it drops & recreates policies).
-- ═══════════════════════════════════════════════════════════════════════

-- ── Extensions ─────────────────────────────────────────────────────────
create extension if not exists pgcrypto;      -- for gen_random_uuid(), crypt()
create extension if not exists "uuid-ossp";

-- ═══════════════════════════════════════════════════════════════════════
--  ENUM TYPES
-- ═══════════════════════════════════════════════════════════════════════
do $$ begin
  create type member_role      as enum ('owner','parent');
  create type tx_type          as enum ('allowance','task_reward','deposit','withdrawal','purchase','gift','transfer_in','transfer_out','penalty','goal_deposit','goal_withdraw','adjustment');
  create type tx_status        as enum ('pending','approved','rejected');
  create type task_status      as enum ('assigned','submitted','approved','rejected');
  create type goal_status      as enum ('active','completed','cancelled');
  create type purchase_status  as enum ('pending','approved','rejected','fulfilled');
  create type plan_tier        as enum ('free','family','premium');
exception when duplicate_object then null; end $$;

-- ═══════════════════════════════════════════════════════════════════════
--  TABLE: profiles   (1-to-1 with auth.users — the parent / account owner)
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  full_name    text,
  phone        text,
  locale       text default 'ar' check (locale in ('ar','en')),
  plan         plan_tier default 'free',
  created_at   timestamptz default now(),
  updated_at   timestamptz default now()
);

-- ═══════════════════════════════════════════════════════════════════════
--  TABLE: families
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists public.families (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  -- short human code used for independent child login (e.g. "SMITH-4821")
  family_code   text unique not null default upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
  owner_id      uuid not null references public.profiles(id) on delete cascade,
  currency_name text default 'عملة',            -- name of the virtual currency
  -- supervision_level: 0=child free, 1=notify parent, 2=parent must approve
  supervision_level smallint default 2 check (supervision_level between 0 and 2),
  settings      jsonb default '{}'::jsonb,        -- flexible per-family config
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);
create index if not exists idx_families_owner on public.families(owner_id);

-- ═══════════════════════════════════════════════════════════════════════
--  TABLE: family_members   (parents linked to families — multi-parent ready)
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists public.family_members (
  family_id   uuid references public.families(id) on delete cascade,
  profile_id  uuid references public.profiles(id) on delete cascade,
  role        member_role default 'parent',
  created_at  timestamptz default now(),
  primary key (family_id, profile_id)
);
create index if not exists idx_family_members_profile on public.family_members(profile_id);

-- ═══════════════════════════════════════════════════════════════════════
--  TABLE: children
--  Children have NO auth.users row. They authenticate via a PIN (hashed).
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists public.children (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null references public.families(id) on delete cascade,
  name         text not null,
  username     text not null,                    -- unique within family
  pin_hash     text not null,                    -- bcrypt hash of the 4-digit PIN
  avatar       text default '🧒',
  color        text default '#00C4B6',
  balance      bigint default 0,                 -- denormalised; maintained by trigger
  level        smallint default 1,
  birth_year   smallint,
  active       boolean default true,
  created_at   timestamptz default now(),
  updated_at   timestamptz default now(),
  unique (family_id, username)
);
create index if not exists idx_children_family on public.children(family_id);

-- ═══════════════════════════════════════════════════════════════════════
--  TABLE: transactions   (double-entry-style ledger)
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists public.transactions (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null references public.families(id) on delete cascade,
  child_id     uuid references public.children(id) on delete cascade,
  type         tx_type not null,
  amount       bigint not null,                  -- signed: + credit, - debit (child perspective)
  description  text,
  status       tx_status default 'approved',
  created_by   uuid references public.profiles(id),  -- parent who created it (null = child request)
  approved_by  uuid references public.profiles(id),
  meta         jsonb default '{}'::jsonb,
  created_at   timestamptz default now()
);
create index if not exists idx_tx_family  on public.transactions(family_id);
create index if not exists idx_tx_child   on public.transactions(child_id);
create index if not exists idx_tx_status  on public.transactions(status);

-- ═══════════════════════════════════════════════════════════════════════
--  TABLE: tasks
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists public.tasks (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null references public.families(id) on delete cascade,
  child_id     uuid references public.children(id) on delete cascade,
  title        text not null,
  description  text,
  reward       bigint not null default 0,
  status       task_status default 'assigned',
  icon         text default '📋',
  due_date     date,
  recurring    text,                             -- null | 'daily' | 'weekly'
  created_by   uuid references public.profiles(id),
  created_at   timestamptz default now(),
  updated_at   timestamptz default now()
);
create index if not exists idx_tasks_family on public.tasks(family_id);
create index if not exists idx_tasks_child  on public.tasks(child_id);

-- ═══════════════════════════════════════════════════════════════════════
--  TABLE: savings_goals
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists public.savings_goals (
  id             uuid primary key default gen_random_uuid(),
  family_id      uuid not null references public.families(id) on delete cascade,
  child_id       uuid not null references public.children(id) on delete cascade,
  title          text not null,
  icon           text default '🎯',
  target_amount  bigint not null check (target_amount > 0),
  current_amount bigint default 0,
  status         goal_status default 'active',
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);
create index if not exists idx_goals_child on public.savings_goals(child_id);

-- ═══════════════════════════════════════════════════════════════════════
--  TABLE: store_items   (treasure shop catalogue, per family)
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists public.store_items (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.families(id) on delete cascade,
  title       text not null,
  icon        text default '🎁',
  cost        bigint not null check (cost >= 0),
  active      boolean default true,
  created_at  timestamptz default now()
);
create index if not exists idx_store_family on public.store_items(family_id);

-- ═══════════════════════════════════════════════════════════════════════
--  TABLE: purchases   (child purchase requests → parent approval)
-- ═══════════════════════════════════════════════════════════════════════
create table if not exists public.purchases (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.families(id) on delete cascade,
  child_id    uuid not null references public.children(id) on delete cascade,
  item_id     uuid references public.store_items(id) on delete set null,
  title       text not null,
  cost        bigint not null,
  status      purchase_status default 'pending',
  created_at  timestamptz default now(),
  decided_at  timestamptz
);
create index if not exists idx_purchases_family on public.purchases(family_id);

-- ═══════════════════════════════════════════════════════════════════════
--  HELPER: is the current auth user a parent of :fid ?
-- ═══════════════════════════════════════════════════════════════════════
create or replace function public.is_family_parent(fid uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from public.family_members
    where family_id = fid and profile_id = auth.uid()
  );
$$;

-- ═══════════════════════════════════════════════════════════════════════
--  TRIGGER: on new auth user → create profile + a default family + membership
-- ═══════════════════════════════════════════════════════════════════════
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  new_family_id uuid;
  fam_name text;
begin
  -- 1. profile
  insert into public.profiles (id, full_name, locale)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)),
    coalesce(new.raw_user_meta_data->>'locale','ar')
  )
  on conflict (id) do nothing;

  -- 2. default family
  fam_name := coalesce(new.raw_user_meta_data->>'family_name',
                       'عائلة ' || coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)));
  insert into public.families (name, owner_id)
  values (fam_name, new.id)
  returning id into new_family_id;

  -- 3. owner membership
  insert into public.family_members (family_id, profile_id, role)
  values (new_family_id, new.id, 'owner');

  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ═══════════════════════════════════════════════════════════════════════
--  TRIGGER: maintain child.balance from approved transactions
-- ═══════════════════════════════════════════════════════════════════════
create or replace function public.apply_tx_to_balance()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- INSERT of an approved tx
  if (tg_op = 'INSERT') then
    if new.status = 'approved' and new.child_id is not null then
      update public.children set balance = balance + new.amount, updated_at = now()
      where id = new.child_id;
    end if;
    return new;
  end if;

  -- UPDATE: status transition to/from approved
  if (tg_op = 'UPDATE') then
    if new.child_id is not null then
      if old.status <> 'approved' and new.status = 'approved' then
        update public.children set balance = balance + new.amount, updated_at = now()
        where id = new.child_id;
      elsif old.status = 'approved' and new.status <> 'approved' then
        update public.children set balance = balance - old.amount, updated_at = now()
        where id = new.child_id;
      end if;
    end if;
    return new;
  end if;

  -- DELETE of an approved tx → reverse
  if (tg_op = 'DELETE') then
    if old.status = 'approved' and old.child_id is not null then
      update public.children set balance = balance - old.amount, updated_at = now()
      where id = old.child_id;
    end if;
    return old;
  end if;

  return null;
end $$;

drop trigger if exists trg_tx_balance on public.transactions;
create trigger trg_tx_balance
  after insert or update or delete on public.transactions
  for each row execute function public.apply_tx_to_balance();

-- ═══════════════════════════════════════════════════════════════════════
--  RPC: create_child  (parent creates a child with a hashed PIN)
-- ═══════════════════════════════════════════════════════════════════════
create or replace function public.create_child(
  p_family_id uuid,
  p_name      text,
  p_username  text,
  p_pin       text,
  p_avatar    text default '🧒',
  p_color     text default '#00C4B6'
)
returns public.children
language plpgsql security definer set search_path = public as $$
declare rec public.children;
begin
  if not public.is_family_parent(p_family_id) then
    raise exception 'not authorised for this family';
  end if;
  if p_pin !~ '^\d{4}$' then
    raise exception 'PIN must be exactly 4 digits';
  end if;

  insert into public.children (family_id, name, username, pin_hash, avatar, color)
  values (p_family_id, p_name, lower(p_username), crypt(p_pin, gen_salt('bf')), p_avatar, p_color)
  returning * into rec;

  rec.pin_hash := null;  -- never return the hash
  return rec;
end $$;

-- ═══════════════════════════════════════════════════════════════════════
--  RPC: set_child_pin  (parent resets a child PIN)
-- ═══════════════════════════════════════════════════════════════════════
create or replace function public.set_child_pin(p_child_id uuid, p_pin text)
returns void language plpgsql security definer set search_path = public as $$
declare fid uuid;
begin
  select family_id into fid from public.children where id = p_child_id;
  if fid is null or not public.is_family_parent(fid) then
    raise exception 'not authorised';
  end if;
  if p_pin !~ '^\d{4}$' then
    raise exception 'PIN must be exactly 4 digits';
  end if;
  update public.children set pin_hash = crypt(p_pin, gen_salt('bf')), updated_at = now()
  where id = p_child_id;
end $$;

-- ═══════════════════════════════════════════════════════════════════════
--  RPC: child_login  (independent child login by family_code + username + PIN)
--  Returns the child row (no hash) if the PIN matches. SECURITY DEFINER so it
--  can read across RLS; it only ever returns ONE verified child.
-- ═══════════════════════════════════════════════════════════════════════
create or replace function public.child_login(
  p_family_code text,
  p_username    text,
  p_pin         text
)
returns table (
  child_id uuid, family_id uuid, name text, username text,
  avatar text, color text, balance bigint, level smallint
)
language plpgsql security definer set search_path = public as $$
declare rec public.children; fid uuid;
begin
  select id into fid from public.families where family_code = upper(p_family_code);
  if fid is null then
    raise exception 'family not found';
  end if;

  select * into rec from public.children
  where family_id = fid and username = lower(p_username) and active = true;

  if rec.id is null then
    raise exception 'child not found';
  end if;
  if rec.pin_hash <> crypt(p_pin, rec.pin_hash) then
    raise exception 'wrong PIN';
  end if;

  return query select rec.id, rec.family_id, rec.name, rec.username,
                      rec.avatar, rec.color, rec.balance, rec.level;
end $$;

-- ═══════════════════════════════════════════════════════════════════════
--  ROW LEVEL SECURITY
-- ═══════════════════════════════════════════════════════════════════════
alter table public.profiles       enable row level security;
alter table public.families       enable row level security;
alter table public.family_members enable row level security;
alter table public.children       enable row level security;
alter table public.transactions   enable row level security;
alter table public.tasks          enable row level security;
alter table public.savings_goals  enable row level security;
alter table public.store_items    enable row level security;
alter table public.purchases      enable row level security;

-- profiles: a user sees & edits only their own profile
drop policy if exists p_profiles_self on public.profiles;
create policy p_profiles_self on public.profiles
  for all using (id = auth.uid()) with check (id = auth.uid());

-- families: members can read; only owner can update/delete; any auth user can insert (they become owner)
drop policy if exists p_fam_select on public.families;
create policy p_fam_select on public.families
  for select using (public.is_family_parent(id));
drop policy if exists p_fam_insert on public.families;
create policy p_fam_insert on public.families
  for insert with check (owner_id = auth.uid());
drop policy if exists p_fam_update on public.families;
create policy p_fam_update on public.families
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists p_fam_delete on public.families;
create policy p_fam_delete on public.families
  for delete using (owner_id = auth.uid());

-- family_members: members can read their rows; owner manages
drop policy if exists p_fm_select on public.family_members;
create policy p_fm_select on public.family_members
  for select using (profile_id = auth.uid() or public.is_family_parent(family_id));
drop policy if exists p_fm_write on public.family_members;
create policy p_fm_write on public.family_members
  for all using (public.is_family_parent(family_id)) with check (public.is_family_parent(family_id));

-- generic family-scoped policy applied to the rest
drop policy if exists p_children_all on public.children;
create policy p_children_all on public.children
  for all using (public.is_family_parent(family_id)) with check (public.is_family_parent(family_id));

drop policy if exists p_tx_all on public.transactions;
create policy p_tx_all on public.transactions
  for all using (public.is_family_parent(family_id)) with check (public.is_family_parent(family_id));

drop policy if exists p_tasks_all on public.tasks;
create policy p_tasks_all on public.tasks
  for all using (public.is_family_parent(family_id)) with check (public.is_family_parent(family_id));

drop policy if exists p_goals_all on public.savings_goals;
create policy p_goals_all on public.savings_goals
  for all using (public.is_family_parent(family_id)) with check (public.is_family_parent(family_id));

drop policy if exists p_store_all on public.store_items;
create policy p_store_all on public.store_items
  for all using (public.is_family_parent(family_id)) with check (public.is_family_parent(family_id));

drop policy if exists p_purch_all on public.purchases;
create policy p_purch_all on public.purchases
  for all using (public.is_family_parent(family_id)) with check (public.is_family_parent(family_id));

-- ═══════════════════════════════════════════════════════════════════════
--  updated_at auto-touch
-- ═══════════════════════════════════════════════════════════════════════
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

do $$
declare t text;
begin
  foreach t in array array['profiles','families','children','tasks','savings_goals'] loop
    execute format('drop trigger if exists trg_touch_%1$s on public.%1$s;', t);
    execute format('create trigger trg_touch_%1$s before update on public.%1$s
                    for each row execute function public.touch_updated_at();', t);
  end loop;
end $$;

-- ═══════════════════════════════════════════════════════════════════════
--  GRANTS (anon can call child_login RPC; authenticated gets the rest via RLS)
-- ═══════════════════════════════════════════════════════════════════════
grant execute on function public.child_login(text,text,text)   to anon, authenticated;
grant execute on function public.create_child(uuid,text,text,text,text,text) to authenticated;
grant execute on function public.set_child_pin(uuid,text)      to authenticated;
grant execute on function public.is_family_parent(uuid)        to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
--  DONE.  Next: enable Email auth in Auth → Providers, and (recommended)
--  turn ON "Confirm email" in Auth → Settings for commercial security.
-- ═══════════════════════════════════════════════════════════════════════
