-- Bluejay Wispr cloud accounts: orgs, members, dictation history, leaderboard.
-- Portable Postgres (no Supabase-specific types or auth.users reference).
-- Apply with: psql "$WISPR_DATABASE_URL" -f db/schema.sql

create extension if not exists pgcrypto;   -- gen_random_uuid()

-- Who is asking. PostgREST puts the verified JWT in request.jwt.claims, and
-- Supabase's auth.uid() is exactly this expression — spelling it out keeps the
-- schema applyable (and testable) on a plain Postgres.
create function current_user_id() returns uuid
language sql stable as $$
    select nullif(nullif(current_setting('request.jwt.claims', true), '')::json ->> 'sub', '')::uuid
$$;

create table users (
    id           uuid primary key default gen_random_uuid(),
    email        text not null unique,
    display_name text,
    created_at   timestamptz not null default now()
);

create table orgs (
    id         uuid primary key default gen_random_uuid(),
    name       text not null,
    created_by uuid not null references users (id),
    created_at timestamptz not null default now()
);

create table org_members (
    org_id       uuid not null references orgs (id) on delete cascade,
    user_id      uuid not null references users (id) on delete cascade,
    display_name text not null,
    role         text not null default 'member' check (role in ('owner', 'member')),
    joined_at    timestamptz not null default now(),
    primary key (org_id, user_id)
);

-- security definer so a policy on org_members can ask about org_members
-- without recursing into itself.
create function is_org_member(org uuid) returns boolean
language sql stable security definer set search_path = public as $$
    select exists (select 1 from org_members
                   where org_id = org and user_id = current_user_id())
$$;

create function is_org_owner(org uuid) returns boolean
language sql stable security definer set search_path = public as $$
    select exists (select 1 from org_members
                   where org_id = org and user_id = current_user_id() and role = 'owner')
$$;

create table invites (
    id          uuid primary key default gen_random_uuid(),
    org_id      uuid not null references orgs (id) on delete cascade,
    email       text not null,
    code        text not null unique,
    invited_by  uuid references users (id),
    expires_at  timestamptz not null,
    accepted_at timestamptz,
    accepted_by uuid references users (id)
);

-- One row per dictation. `id` is the client-minted DictationEntry.id, so every
-- push is an upsert and retries are free.
create table dictations (
    id               uuid primary key,
    user_id          uuid not null references users (id) on delete cascade,
    org_id           uuid references orgs (id) on delete set null,
    created_at       timestamptz not null,
    word_count       integer not null check (word_count >= 0),
    duration_seconds double precision not null check (duration_seconds >= 0),
    app_name         text,
    bundle_id        text,
    provider         text,
    synced_at        timestamptz not null default now()
);

create index dictations_org_created_idx on dictations (org_id, created_at desc);
create index dictations_user_created_idx on dictations (user_id, created_at desc);

-- Transcript text is a separate table with a separate opt-in, so "sync my stats
-- but not my words" is a grant you can withhold rather than client-side good
-- intentions. Nothing below this line reads it; the leaderboard never does.
create table dictation_texts (
    dictation_id uuid primary key references dictations (id) on delete cascade,
    raw          text not null,
    cleaned      text not null
);

-- ponytail: days bucketed in UTC, so a dictation after 5pm PT counts as
-- tomorrow and can pad or break a streak. Store the client's UTC offset on
-- dictations and bucket by local date if streaks start reading wrong.
create view member_days as
select user_id,
       org_id,
       (created_at at time zone 'UTC')::date as day,
       sum(word_count)::bigint               as words,
       sum(duration_seconds)                 as seconds
from dictations
group by user_id, org_id, (created_at at time zone 'UTC')::date;

-- Current run of consecutive active days, counted only if it reaches today or
-- yesterday (gaps-and-islands: consecutive days share day - row_number()).
create view member_streaks as
with days as (
    select distinct user_id, day from member_days
),
islands as (
    select user_id,
           max(day)     as last_day,
           count(*)::int as length
    from (
        select user_id,
               day,
               day - (row_number() over (partition by user_id order by day))::int as island
        from days
    ) g
    group by user_id, island
)
select user_id,
       coalesce(max(length) filter (where last_day >= current_date - 1), 0) as day_streak
from islands
group by user_id;

-- One row per (org, member, period). Clients filter and sort server-side:
--   ?org_id=eq.<id>&period=eq.week&order=words.desc
--
-- Deliberately NOT security_invoker. A member can only select their own rows in
-- `dictations` (policies.sql), so an invoker-rights view would show everyone a
-- leaderboard of one: themselves. Reading as owner is what lets this aggregate
-- across the team, and the is_org_member predicate below is the entire access
-- control for it — it is not redundant with RLS, it replaces it here. Only
-- aggregates cross that line; nobody sees another member's rows, timestamps or
-- app names, and no view here can reach transcript text.
create view leaderboard as
select m.org_id,
       m.user_id,
       om.display_name,
       p.period,
       sum(m.words)::bigint as words,
       case when sum(m.seconds) > 0
            then round((sum(m.words) / (sum(m.seconds) / 60.0))::numeric, 1)
       end                  as wpm,
       coalesce(s.day_streak, 0) as day_streak
from member_days m
join org_members om on om.org_id = m.org_id and om.user_id = m.user_id
left join member_streaks s on s.user_id = m.user_id
cross join (values ('day', 1), ('week', 7), ('month', 30), ('all', 100000))
        as p (period, days)
where m.day > current_date - p.days
  and is_org_member(m.org_id)
group by m.org_id, m.user_id, om.display_name, p.period, s.day_streak;

-- `users.id` IS `auth.users.id`, and this is what makes it so. Without the trigger
-- a sign-in creates the auth row and nothing else, so every policy in
-- policies.sql — all of which key off `auth.uid()` against this table — matches no
-- row and the signed-in user sees an empty app. The default on `id` goes away
-- because the id now comes from auth, not from us; leaving it would let an insert
-- mint a row belonging to nobody.
--
-- Supabase-only: it references the `auth` schema, so a plain Postgres skips from
-- here down.
alter table users alter column id drop default;
alter table users add constraint users_auth_fk
    foreign key (id) references auth.users (id) on delete cascade;

create function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
    insert into public.users (id, email, display_name)
    values (new.id, new.email, new.raw_user_meta_data ->> 'display_name')
    on conflict (id) do nothing;
    return new;
end $$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function handle_new_user();
