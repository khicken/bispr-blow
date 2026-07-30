-- Bluejay Wispr cloud accounts: orgs, members, dictation history, leaderboard.
-- Portable Postgres (no Supabase-specific types or auth.users reference).
-- Apply with: psql "$WISPR_DATABASE_URL" -f db/schema.sql

create extension if not exists pgcrypto;   -- gen_random_uuid()

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
group by m.org_id, m.user_id, om.display_name, p.period, s.day_streak;
