-- Team features + leaderboard fix, for the LIVE database. Safe to run twice.
-- Paste into the Supabase SQL editor (runs as postgres).
--
-- Run this first to see the problem (security_invoker = on in reloptions on
-- leaderboard is the cause of "permission denied for view member_days"):
--   select c.relname, pg_get_userbyid(c.relowner) as owner, c.reloptions from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname in ('leaderboard','member_days','member_streaks');

-- 1. Leaderboard: owner-rights again. With security_invoker on, the caller
--    needs select on member_days, which is deliberately revoked from them.
--    Owner must be a role that can read the base tables (postgres).
alter view leaderboard    owner to postgres;
alter view member_days    owner to postgres;
alter view member_streaks owner to postgres;
alter view leaderboard    set (security_invoker = false);
alter view member_days    set (security_invoker = false);
alter view member_streaks set (security_invoker = false);
grant select on leaderboard to authenticated;
revoke all on member_days, member_streaks from authenticated, anon;

-- 2. Org rename: orgs_update_owner already exists; only the name rule is new.
--    NOT VALID so a legacy blank name cannot block the migration; it still
--    applies to every new insert and update.
alter table orgs drop constraint if exists orgs_name_not_blank;
alter table orgs add constraint orgs_name_not_blank check (btrim(name) <> '') not valid;

drop policy if exists orgs_update_owner on orgs;
create policy orgs_update_owner on orgs
    for update using (is_org_owner(id)) with check (is_org_owner(id));

-- 3. Roster with emails.
create or replace function shares_org_with(other uuid) returns boolean
language sql stable security definer set search_path = public as $$
    select other = current_user_id()
        or exists (select 1
                   from org_members mine
                   join org_members theirs on theirs.org_id = mine.org_id
                   where mine.user_id = current_user_id() and theirs.user_id = other)
$$;

drop policy if exists users_read_comembers on users;
create policy users_read_comembers on users
    for select using (shares_org_with(id));

-- 4. Shared dictionaries.
create table if not exists dictionary_words (
    user_id    uuid not null references users (id) on delete cascade,
    word       text not null check (btrim(word) <> '' and char_length(word) <= 200),
    updated_at timestamptz not null default now(),
    primary key (user_id, word)
);

alter table dictionary_words enable row level security;

drop policy if exists words_read_comembers on dictionary_words;
create policy words_read_comembers on dictionary_words
    for select using (shares_org_with(user_id));
drop policy if exists words_insert_self on dictionary_words;
create policy words_insert_self on dictionary_words
    for insert with check (user_id = current_user_id());
drop policy if exists words_update_self on dictionary_words;
create policy words_update_self on dictionary_words
    for update using (user_id = current_user_id()) with check (user_id = current_user_id());
drop policy if exists words_delete_self on dictionary_words;
create policy words_delete_self on dictionary_words
    for delete using (user_id = current_user_id());

-- Supabase's default privileges hand new tables to anon; take them back.
revoke all on dictionary_words from anon;
grant select, insert, update, delete on dictionary_words to authenticated;

-- Make PostgREST see the new table and policies right away.
notify pgrst, 'reload schema';
