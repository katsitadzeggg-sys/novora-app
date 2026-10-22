-- Novora: ოსტატები, კლიენტები, პროექტები, ფოტოები, კატალოგი
create extension if not exists pgcrypto;

-- ოსტატის პროფილი (1:1 auth.users-თან)
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'master' check (role in ('master','admin')),
  full_name text,
  phone text,
  city text,
  bio text,
  slug text unique,
  avatar_path text,
  is_public boolean not null default false,
  plan text not null default 'trial' check (plan in ('trial','active','expired')),
  plan_until date,
  created_at timestamptz not null default now()
);

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- ახალი მომხმარებელი -> პროფილი
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (new.id, new.raw_user_meta_data->>'full_name', new.phone)
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ოსტატის კლიენტები
create table if not exists public.clients (
  id uuid primary key default gen_random_uuid(),
  master_id uuid not null references public.profiles(id) on delete cascade,
  full_name text not null,
  phone text,
  address text,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists clients_master_idx on public.clients(master_id);

-- პროექტები
create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  master_id uuid not null references public.profiles(id) on delete cascade,
  client_id uuid references public.clients(id) on delete set null,
  title text not null,
  status text not null default 'measure'
    check (status in ('measure','design','offer','production','install','done')),
  state jsonb not null default '{}'::jsonb,     -- კონსტრუქტორის მდგომარეობა
  summary jsonb not null default '{}'::jsonb,   -- ფილები, კრომკა, ფურნიტურა
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists projects_master_idx on public.projects(master_id);
create index if not exists projects_client_idx on public.projects(client_id);

create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;
drop trigger if exists projects_touch on public.projects;
create trigger projects_touch before update on public.projects
  for each row execute function public.touch_updated_at();

-- ფოტოები და ფაილები (ამონაწერი, ესკიზი, პროცესი, საბოლოო შედეგი)
create table if not exists public.project_files (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  master_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null default 'other'
    check (kind in ('extract','sketch','measure','process','final','other')),
  path text not null,               -- storage: project-files/<master_id>/<project_id>/<file>
  caption text,
  is_public boolean not null default false,   -- ოსტატის გალერეაში
  created_at timestamptz not null default now()
);
create index if not exists files_project_idx on public.project_files(project_id);

-- Novora-ს პროდუქციის კატალოგი
create table if not exists public.catalog_items (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  category text not null,
  description text,
  price numeric(10,2),
  unit text default 'ც.',
  image_path text,
  model jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- RLS
alter table public.profiles enable row level security;
alter table public.clients enable row level security;
alter table public.projects enable row level security;
alter table public.project_files enable row level security;
alter table public.catalog_items enable row level security;

drop policy if exists "profiles self read" on public.profiles;
create policy "profiles self read" on public.profiles for select
  using (id = auth.uid() or is_public or public.is_admin());
drop policy if exists "profiles self update" on public.profiles;
create policy "profiles self update" on public.profiles for update
  using (id = auth.uid() or public.is_admin())
  with check (id = auth.uid() or public.is_admin());
-- ოსტატი role/plan-ს ვერ შეცვლის
create or replace function public.guard_profile() returns trigger language plpgsql as $$
begin
  if not public.is_admin() then
    new.role := old.role; new.plan := old.plan; new.plan_until := old.plan_until;
  end if;
  return new;
end; $$;
drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before update on public.profiles
  for each row execute function public.guard_profile();

drop policy if exists "clients own" on public.clients;
create policy "clients own" on public.clients for all
  using (master_id = auth.uid()) with check (master_id = auth.uid());

drop policy if exists "projects own" on public.projects;
create policy "projects own" on public.projects for all
  using (master_id = auth.uid()) with check (master_id = auth.uid());
drop policy if exists "projects admin read" on public.projects;
create policy "projects admin read" on public.projects for select using (public.is_admin());

drop policy if exists "files own" on public.project_files;
create policy "files own" on public.project_files for all
  using (master_id = auth.uid()) with check (master_id = auth.uid());
drop policy if exists "files public" on public.project_files;
create policy "files public" on public.project_files for select
  using (is_public and kind = 'final');

drop policy if exists "catalog read" on public.catalog_items;
create policy "catalog read" on public.catalog_items for select using (active or public.is_admin());
drop policy if exists "catalog admin" on public.catalog_items;
create policy "catalog admin" on public.catalog_items for all
  using (public.is_admin()) with check (public.is_admin());

-- Storage
insert into storage.buckets (id, name, public) values ('project-files','project-files', false)
  on conflict (id) do nothing;
insert into storage.buckets (id, name, public) values ('catalog','catalog', true)
  on conflict (id) do nothing;

drop policy if exists "files own rw" on storage.objects;
create policy "files own rw" on storage.objects for all
  using (bucket_id = 'project-files' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'project-files' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "catalog public read" on storage.objects;
create policy "catalog public read" on storage.objects for select using (bucket_id = 'catalog');
drop policy if exists "catalog admin write" on storage.objects;
create policy "catalog admin write" on storage.objects for all
  using (bucket_id = 'catalog' and public.is_admin()) with check (bucket_id = 'catalog' and public.is_admin());
