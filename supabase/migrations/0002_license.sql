-- Novora 0002: ლიცენზია, მოწყობილობები, AI ლიმიტი, დასრულებული პროექტები და რეიტინგი
-- ადმინის ელფოსტა: ჩაანაცვლეთ admin@novora.example რეალური მისამართით გაშვებამდე
-- გაშვება: Supabase → SQL Editor → ჩასვით მთლიანად → Run. შეიძლება რამდენჯერმე გაეშვას.

-- პროფილი: ელფოსტა, AI-ის თვიური ლიმიტი
alter table public.profiles add column if not exists email text;
alter table public.profiles add column if not exists ai_limit int not null default 30;

-- ახალი მომხმარებელი -> პროფილი (ადმინი ელფოსტით)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, phone, city, email, role)
  values (new.id,
          new.raw_user_meta_data->>'full_name',
          coalesce(new.raw_user_meta_data->>'phone', new.phone),
          new.raw_user_meta_data->>'city',
          new.email,
          case when lower(new.email) = 'admin@novora.example' then 'admin' else 'master' end)
  on conflict (id) do nothing;
  return new;
end;
$$;

update public.profiles p set email = u.email from auth.users u where u.id = p.id and p.email is null;
update public.profiles set role = 'admin' where lower(email) = 'admin@novora.example';

-- აქტიური ლიცენზია: ადმინი, ან plan = active და ვადა არ გასულა
create or replace function public.has_license(uid uuid default auth.uid()) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles
    where id = uid and (role = 'admin' or (plan = 'active' and (plan_until is null or plan_until >= current_date))));
$$;

-- მოწყობილობები: ერთ ანგარიშზე მაქსიმუმ 2
create table if not exists public.devices (
  user_id uuid not null references public.profiles(id) on delete cascade,
  device_id text not null,
  label text,
  last_seen timestamptz not null default now(),
  created_at timestamptz not null default now(),
  primary key (user_id, device_id)
);
alter table public.devices enable row level security;
drop policy if exists "devices own read" on public.devices;
create policy "devices own read" on public.devices for select using (user_id = auth.uid() or public.is_admin());
drop policy if exists "devices admin delete" on public.devices;
create policy "devices admin delete" on public.devices for delete using (public.is_admin());

create or replace function public.claim_device(p_device text, p_label text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); pr public.profiles;
begin
  if uid is null then raise exception 'not signed in'; end if;
  insert into public.devices(user_id, device_id, label) values (uid, p_device, p_label)
    on conflict (user_id, device_id) do update set last_seen = now(), label = coalesce(excluded.label, public.devices.label);
  delete from public.devices where user_id = uid and device_id in (
    select device_id from public.devices where user_id = uid order by last_seen desc offset 2);
  select * into pr from public.profiles where id = uid;
  return jsonb_build_object('license', public.has_license(uid), 'role', pr.role, 'plan', pr.plan,
    'until', pr.plan_until, 'name', pr.full_name, 'email', pr.email, 'phone', pr.phone);
end; $$;

create or replace function public.device_ok(p_device text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); ok boolean;
begin
  if uid is null then return jsonb_build_object('device', false, 'license', false); end if;
  update public.devices set last_seen = now() where user_id = uid and device_id = p_device;
  ok := found;
  return jsonb_build_object('device', ok, 'license', public.has_license(uid));
end; $$;

-- AI ფოტოს მოხმარება და თვიური ლიმიტი
create table if not exists public.ai_usage (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists ai_usage_user_idx on public.ai_usage(user_id, created_at);
alter table public.ai_usage enable row level security;
drop policy if exists "ai own read" on public.ai_usage;
create policy "ai own read" on public.ai_usage for select using (user_id = auth.uid() or public.is_admin());

create or replace function public.use_ai() returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); used int; lim int;
begin
  if uid is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  if not public.has_license(uid) then return jsonb_build_object('ok', false, 'reason', 'license'); end if;
  select ai_limit into lim from public.profiles where id = uid;
  select count(*) into used from public.ai_usage where user_id = uid and created_at >= date_trunc('month', now());
  if used >= lim and not public.is_admin() then return jsonb_build_object('ok', false, 'reason', 'limit', 'used', used, 'limit', lim); end if;
  insert into public.ai_usage(user_id) values (uid);
  return jsonb_build_object('ok', true, 'used', used + 1, 'limit', lim);
end; $$;

-- პროექტი: დასრულება, დამკვეთის დადასტურება, შეფასება, საკომისიო
alter table public.projects add column if not exists done_at timestamptz;
alter table public.projects add column if not exists final_path text;
alter table public.projects add column if not exists confirm_token uuid not null default gen_random_uuid();
alter table public.projects add column if not exists confirmed_at timestamptz;
alter table public.projects add column if not exists rating int check (rating between 1 and 5);
alter table public.projects add column if not exists review text;
alter table public.projects add column if not exists fee numeric(10,2) not null default 30;
alter table public.projects add column if not exists fee_paid boolean not null default false;

-- ახალი/შეცვლილი პროექტი მხოლოდ აქტიური ლიცენზიით; დადასტურებას და საკომისიოს ოსტატი ვერ შეცვლის
drop policy if exists "projects own" on public.projects;
drop policy if exists "projects own read" on public.projects;
create policy "projects own read" on public.projects for select using (master_id = auth.uid());
drop policy if exists "projects own insert" on public.projects;
create policy "projects own insert" on public.projects for insert with check (master_id = auth.uid() and public.has_license());
drop policy if exists "projects own update" on public.projects;
create policy "projects own update" on public.projects for update using (master_id = auth.uid() and public.has_license()) with check (master_id = auth.uid());
drop policy if exists "projects own delete" on public.projects;
create policy "projects own delete" on public.projects for delete using (master_id = auth.uid() and confirmed_at is null);
drop policy if exists "projects admin write" on public.projects;
create policy "projects admin write" on public.projects for update using (public.is_admin()) with check (public.is_admin());

create or replace function public.guard_project() returns trigger language plpgsql as $$
begin
  if not public.is_admin() then
    if tg_op = 'UPDATE' then
      new.confirmed_at := old.confirmed_at; new.rating := old.rating; new.review := old.review;
      new.fee := old.fee; new.fee_paid := old.fee_paid; new.confirm_token := old.confirm_token;
    else
      new.confirmed_at := null; new.rating := null; new.review := null; new.fee := 30; new.fee_paid := false;
    end if;
  end if;
  return new;
end; $$;
drop trigger if exists projects_guard on public.projects;
create trigger projects_guard before insert or update on public.projects
  for each row execute function public.guard_project();

-- დამკვეთის გვერდი (შესვლის გარეშე, ბმულით)
create or replace function public.project_public(p_token uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('title', p.title, 'master', pr.full_name, 'phone', pr.phone, 'city', pr.city,
    'final_path', p.final_path, 'done', p.done_at is not null, 'confirmed', p.confirmed_at is not null, 'rating', p.rating)
  from public.projects p join public.profiles pr on pr.id = p.master_id where p.confirm_token = p_token;
$$;

create or replace function public.confirm_project(p_token uuid, p_rating int, p_review text default null) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if p_rating is null or p_rating < 1 or p_rating > 5 then return false; end if;
  update public.projects set confirmed_at = now(), rating = p_rating, review = left(p_review, 1000)
    where confirm_token = p_token and done_at is not null and confirmed_at is null;
  return found;
end; $$;

-- რეიტინგი: დადასტურებული პროექტები და საშუალო შეფასება
create or replace function public.master_ratings() returns table(id uuid, full_name text, city text, done int, avg_rating numeric)
language sql stable security definer set search_path = public as $$
  select pr.id, pr.full_name, pr.city, count(p.id)::int, round(avg(p.rating)::numeric, 2)
  from public.profiles pr join public.projects p on p.master_id = pr.id and p.confirmed_at is not null
  group by pr.id order by avg(p.rating) desc, count(p.id) desc;
$$;

-- ადმინის ცხრილი
create or replace function public.admin_masters() returns table(
  id uuid, email text, full_name text, phone text, city text, role text, plan text, plan_until date, ai_limit int,
  projects int, done int, confirmed int, fees_due numeric, ai_month int, devices int, avg_rating numeric, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  return query
  select pr.id, pr.email, pr.full_name, pr.phone, pr.city, pr.role, pr.plan, pr.plan_until, pr.ai_limit,
    (select count(*)::int from public.projects p where p.master_id = pr.id),
    (select count(*)::int from public.projects p where p.master_id = pr.id and p.done_at is not null),
    (select count(*)::int from public.projects p where p.master_id = pr.id and p.confirmed_at is not null),
    (select coalesce(sum(p.fee), 0) from public.projects p where p.master_id = pr.id and p.done_at is not null and not p.fee_paid),
    (select count(*)::int from public.ai_usage a where a.user_id = pr.id and a.created_at >= date_trunc('month', now())),
    (select count(*)::int from public.devices d where d.user_id = pr.id),
    (select round(avg(p.rating)::numeric, 2) from public.projects p where p.master_id = pr.id and p.rating is not null),
    pr.created_at
  from public.profiles pr order by pr.created_at desc;
end; $$;

create or replace function public.admin_set_license(p_user uuid, p_plan text, p_until date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.profiles set plan = p_plan, plan_until = p_until where id = p_user;
  if p_plan <> 'active' then delete from public.devices where user_id = p_user; end if;
end; $$;

create or replace function public.admin_mark_fees_paid(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'admin only'; end if;
  update public.projects set fee_paid = true where master_id = p_user and done_at is not null and not fee_paid;
end; $$;

-- საბოლოო ფოტოები (საჯარო, დამკვეთის გვერდისთვის და რეიტინგისთვის)
insert into storage.buckets (id, name, public) values ('finals', 'finals', true) on conflict (id) do nothing;
drop policy if exists "finals own write" on storage.objects;
create policy "finals own write" on storage.objects for insert
  with check (bucket_id = 'finals' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "finals own update" on storage.objects;
create policy "finals own update" on storage.objects for update
  using (bucket_id = 'finals' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "finals public read" on storage.objects;
create policy "finals public read" on storage.objects for select using (bucket_id = 'finals');

grant execute on function public.project_public(uuid) to anon, authenticated;
grant execute on function public.confirm_project(uuid, int, text) to anon, authenticated;
grant execute on function public.master_ratings() to anon, authenticated;
