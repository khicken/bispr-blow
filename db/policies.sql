-- Row-level security for the Wispr cloud tables.
-- Apply after db/schema.sql:  psql "$WISPR_DATABASE_URL" -f db/policies.sql
--
-- Every table is deny-by-default and the anon key gets nothing, which is what
-- makes it safe to ship that key inside the app. The rule underneath all of it:
-- your dictations are yours. Teammates see aggregates through the leaderboard
-- view and nothing else, and nobody but you can read your transcript text.

-- Supabase already has these roles; a plain Postgres (or a test container) does not.
do $$ begin
    if not exists (select 1 from pg_roles where rolname = 'authenticated') then
        create role authenticated nologin;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'anon') then
        create role anon nologin;
    end if;
end $$;

alter table users           enable row level security;
alter table orgs            enable row level security;
alter table org_members     enable row level security;
alter table invites         enable row level security;
alter table dictations      enable row level security;
alter table dictation_texts enable row level security;

-- Users: your own row, and the display name you chose.
create policy users_read_self on users
    for select using (id = current_user_id());
create policy users_update_self on users
    for update using (id = current_user_id()) with check (id = current_user_id());

-- Orgs: visible to members, editable by owners. Creating one goes through
-- create_org() below, because the first membership row has to exist before an
-- owner-only policy can let anyone write it.
create policy orgs_read_members on orgs
    for select using (is_org_member(id));
create policy orgs_update_owner on orgs
    for update using (is_org_owner(id)) with check (is_org_owner(id));
create policy orgs_delete_owner on orgs
    for delete using (is_org_owner(id));

-- Membership: the roster is visible to the org. Owners add and remove; you can
-- always rename or remove yourself.
create policy members_read_org on org_members
    for select using (is_org_member(org_id));
create policy members_insert_owner on org_members
    for insert with check (is_org_owner(org_id));
create policy members_update_owner_or_self on org_members
    for update using (is_org_owner(org_id) or user_id = current_user_id())
    with check (is_org_owner(org_id) or user_id = current_user_id());
create policy members_delete_owner_or_self on org_members
    for delete using (is_org_owner(org_id) or user_id = current_user_id());

-- Invites: an owner's business. The person accepting never selects the row —
-- accept_invite() takes the code and does the check itself, so a stolen code
-- cannot also be used to read the invite list.
create policy invites_read_owner on invites
    for select using (is_org_owner(org_id));
create policy invites_insert_owner on invites
    for insert with check (is_org_owner(org_id) and invited_by = current_user_id());
create policy invites_update_owner on invites
    for update using (is_org_owner(org_id)) with check (is_org_owner(org_id));
create policy invites_delete_owner on invites
    for delete using (is_org_owner(org_id));

-- Dictations: yours alone, at the row level. Teammates reach the aggregates
-- through the leaderboard view, never through this table.
create policy dictations_read_self on dictations
    for select using (user_id = current_user_id());
create policy dictations_insert_self on dictations
    for insert with check (user_id = current_user_id()
                           and (org_id is null or is_org_member(org_id)));
create policy dictations_update_self on dictations
    for update using (user_id = current_user_id())
    with check (user_id = current_user_id()
                and (org_id is null or is_org_member(org_id)));
create policy dictations_delete_self on dictations
    for delete using (user_id = current_user_id());

-- Transcript text: no org path at all. Uploading it is an opt-in; being the
-- only one who can read it is not.
create policy texts_own on dictation_texts
    for all using (exists (select 1 from dictations d
                           where d.id = dictation_id and d.user_id = current_user_id()))
    with check (exists (select 1 from dictations d
                        where d.id = dictation_id and d.user_id = current_user_id()));

-- Create an org and become its owner in one step.
create function create_org(name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
    new_id uuid;
    me     uuid := current_user_id();
begin
    if me is null then
        raise exception 'not signed in';
    end if;
    insert into orgs (name, created_by) values (name, me) returning id into new_id;
    insert into org_members (org_id, user_id, display_name, role)
    values (new_id, me, coalesce((select display_name from users where id = me),
                                 (select email from users where id = me)), 'owner');
    return new_id;
end $$;

-- Redeem an invite code. The code alone is not enough — it has to have been
-- issued to your email — so a code pasted into the wrong channel is inert.
create function accept_invite(invite_code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
    inv  invites%rowtype;
    me   uuid := current_user_id();
    mine users%rowtype;
begin
    select * into mine from users where id = me;
    if mine.id is null then
        raise exception 'not signed in';
    end if;

    select * into inv from invites
    where code = invite_code and accepted_at is null and expires_at > now();
    if inv.id is null then
        raise exception 'invite code is not valid';
    end if;
    if lower(inv.email) is distinct from lower(mine.email) then
        raise exception 'invite code was issued to a different address';
    end if;

    insert into org_members (org_id, user_id, display_name, role)
    values (inv.org_id, me, coalesce(mine.display_name, mine.email), 'member')
    on conflict (org_id, user_id) do nothing;

    update invites set accepted_at = now(), accepted_by = me where id = inv.id;
    return inv.org_id;
end $$;

-- The anon key ships inside the app, so anon gets nothing anywhere.
revoke all on all tables in schema public from anon;

grant select, update                     on users           to authenticated;
grant select, update, delete             on orgs            to authenticated;
grant select, insert, update, delete     on org_members     to authenticated;
grant select, insert, update, delete     on invites         to authenticated;
grant select, insert, update, delete     on dictations      to authenticated;
grant select, insert, update, delete     on dictation_texts to authenticated;
grant select                             on leaderboard     to authenticated;

-- member_days and member_streaks are owner-rights internals of the leaderboard
-- with no org predicate of their own. Selecting them directly would hand over
-- every org's history, so nobody gets to.
revoke all on member_days, member_streaks from authenticated, anon;

grant execute on function create_org(text), accept_invite(text) to authenticated;
