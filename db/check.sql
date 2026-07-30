-- Self-check for the leaderboard math and the access rules. Seeds fixtures,
-- asserts as real users, rolls back. Run against a database with schema.sql and
-- policies.sql applied:
--   psql "$WISPR_DATABASE_URL" -v ON_ERROR_STOP=1 -f db/check.sql
-- Silence means every assert passed.

set time zone 'UTC';
begin;

-- Seeded as the owner, which bypasses RLS; every assert below runs as a real
-- signed-in user instead.
insert into users (id, email, display_name) values
    ('11111111-1111-1111-1111-111111111111', 'ada@example.com', 'Ada'),
    ('22222222-2222-2222-2222-222222222222', 'bo@example.com',  'Bo'),
    ('33333333-3333-3333-3333-333333333333', 'cy@example.com',  'Cy'),
    ('44444444-4444-4444-4444-444444444444', 'dee@example.com', 'Dee');

insert into orgs (id, name, created_by)
values ('aaaaaaaa-0000-0000-0000-000000000000', 'Test Org',
        '11111111-1111-1111-1111-111111111111');

insert into org_members (org_id, user_id, display_name, role) values
    ('aaaaaaaa-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111', 'Ada', 'owner'),
    ('aaaaaaaa-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222', 'Bo', 'member'),
    ('aaaaaaaa-0000-0000-0000-000000000000', '33333333-3333-3333-3333-333333333333', 'Cy', 'member');

-- Ada: 300 words / 120s today, 200 words / 60s yesterday.
-- Bo:  100 words / 60s today.
-- Cy:  500 words 10 days ago — outside the week, streak broken.
-- Dee: in no org at all.
insert into dictations (id, user_id, org_id, created_at, word_count, duration_seconds, app_name, provider) values
    ('d1000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000000', now(),                      300, 120, 'Xcode', 'local'),
    ('d2000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000000', now() - interval '1 day',   200,  60, 'Slack', 'local'),
    ('d3000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222', 'aaaaaaaa-0000-0000-0000-000000000000', now(),                      100,  60, 'Slack', 'local'),
    ('d4000000-0000-0000-0000-000000000000', '33333333-3333-3333-3333-333333333333', 'aaaaaaaa-0000-0000-0000-000000000000', now() - interval '10 days', 500, 300, 'Mail',  'local');

insert into dictation_texts (dictation_id, raw, cleaned)
values ('d1000000-0000-0000-0000-000000000000', 'um the thing i said', 'The thing I said');

-- No view that feeds the leaderboard may reach transcript text.
do $$
begin
    assert not exists (
        select 1 from information_schema.view_column_usage
        where view_name in ('leaderboard', 'member_days', 'member_streaks')
          and table_name = 'dictation_texts'),
        'no leaderboard view may read dictation_texts';
end $$;

--------------------------------------------------------------------------------
-- As Ada, a member and owner.
--------------------------------------------------------------------------------
set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
set local role authenticated;

do $$
declare
    row_count integer;
begin
    -- Today: Ada 300 words at 150 wpm, Bo 100 at 100 wpm, Cy absent.
    assert (select words from leaderboard where period = 'day' and display_name = 'Ada') = 300,
        'Ada should have 300 words today';
    assert (select wpm from leaderboard where period = 'day' and display_name = 'Ada') = 150.0,
        'Ada should be at 150 wpm today (300 words / 2 min)';
    assert (select wpm from leaderboard where period = 'day' and display_name = 'Bo') = 100.0,
        'Bo should be at 100 wpm today';
    assert not exists (select 1 from leaderboard where period = 'day' and display_name = 'Cy'),
        'Cy dictated 10 days ago and must not appear in today';

    -- Week: Ada's two days sum, and wpm is over the whole period, not an
    -- average of per-day rates. 500 words / 3 min = 166.7.
    assert (select words from leaderboard where period = 'week' and display_name = 'Ada') = 500,
        'Ada should have 500 words this week';
    assert (select wpm from leaderboard where period = 'week' and display_name = 'Ada') = 166.7,
        'week wpm must divide total words by total minutes';

    select count(*) into row_count from leaderboard where period = 'all';
    assert row_count = 3, 'all-time should list every member, got ' || row_count;

    -- Streaks: consecutive days ending today count, a 10-day-old run does not.
    assert (select day_streak from leaderboard where period = 'all' and display_name = 'Ada') = 2,
        'Ada dictated today and yesterday: streak 2';
    assert (select day_streak from leaderboard where period = 'all' and display_name = 'Bo') = 1,
        'Bo dictated today only: streak 1';
    assert (select day_streak from leaderboard where period = 'all' and display_name = 'Cy') = 0,
        'Cy last dictated 10 days ago: streak 0';
end $$;

--------------------------------------------------------------------------------
-- As Bo, an ordinary member: same board, none of Ada's rows.
--------------------------------------------------------------------------------
reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-2222-2222-222222222222"}';
set local role authenticated;

do $$
begin
    assert (select words from leaderboard where period = 'day' and display_name = 'Ada') = 300,
        'a member sees teammates aggregates on the board';

    assert (select count(*) from dictations) = 1,
        'a member sees only their own dictation rows';
    assert not exists (select 1 from dictations
                       where user_id = '11111111-1111-1111-1111-111111111111'),
        'Ada''s dictation rows, timestamps and app names stay hers';
    assert not exists (select 1 from dictation_texts),
        'transcript text is never readable by a teammate';

    assert (select count(*) from org_members) = 3, 'the roster is visible to the org';
end $$;

-- The leaderboard's internals have no org predicate, so they are not selectable.
do $$
begin
    perform 1 from member_days limit 1;
    raise exception 'member_days must not be selectable by a signed-in user';
exception
    when insufficient_privilege then null;
end $$;

-- Re-pushing a dictation upserts on the client-minted id rather than duplicating.
insert into dictations (id, user_id, org_id, created_at, word_count, duration_seconds, provider)
values ('dddddddd-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222',
        'aaaaaaaa-0000-0000-0000-000000000000', now(), 10, 10, 'local');
insert into dictations (id, user_id, org_id, created_at, word_count, duration_seconds, provider)
values ('dddddddd-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222',
        'aaaaaaaa-0000-0000-0000-000000000000', now(), 25, 10, 'local')
on conflict (id) do update set word_count = excluded.word_count, synced_at = now();

insert into dictation_texts (dictation_id, raw, cleaned)
values ('dddddddd-0000-0000-0000-000000000000', 'um hello', 'Hello');

do $$
begin
    assert (select count(*) from dictations
            where id = 'dddddddd-0000-0000-0000-000000000000') = 1,
        'a re-pushed dictation must upsert, not duplicate';
    assert (select word_count from dictations
            where id = 'dddddddd-0000-0000-0000-000000000000') = 25,
        'the upsert must win over the stale row';
    assert (select words from leaderboard
            where period = 'day' and display_name = 'Bo') = 125,
        'Bo today: 100 + the 25-word upsert';
end $$;

-- Writing a dictation into someone else's name is refused.
do $$
begin
    insert into dictations (id, user_id, org_id, created_at, word_count, duration_seconds, provider)
    values (gen_random_uuid(), '11111111-1111-1111-1111-111111111111',
            'aaaaaaaa-0000-0000-0000-000000000000', now(), 9999, 1, 'local');
    raise exception 'a member must not be able to write rows as another user';
exception
    when insufficient_privilege then null;
end $$;

-- Deleting a dictation takes its text with it.
delete from dictations where id = 'dddddddd-0000-0000-0000-000000000000';
do $$
begin
    assert not exists (select 1 from dictation_texts
                       where dictation_id = 'dddddddd-0000-0000-0000-000000000000'),
        'dictation_texts must cascade with its dictation';
end $$;

--------------------------------------------------------------------------------
-- As Dee, who is in no org: the board is empty, not someone else's.
--------------------------------------------------------------------------------
reset role;
set local request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';
set local role authenticated;

do $$
begin
    assert not exists (select 1 from leaderboard),
        'an outsider must see no leaderboard rows at all';
    assert not exists (select 1 from orgs), 'an outsider must not see the org';
    assert not exists (select 1 from org_members), 'an outsider must not see the roster';
end $$;

--------------------------------------------------------------------------------
-- Invites: the code has to have been issued to you.
--------------------------------------------------------------------------------
reset role;
insert into invites (id, org_id, email, code, invited_by, expires_at) values
    ('11110000-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000000',
     'dee@example.com', 'GOODCODE', '11111111-1111-1111-1111-111111111111', now() + interval '7 days'),
    ('22220000-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000000',
     'someone@example.com', 'WRONGPERSON', '11111111-1111-1111-1111-111111111111', now() + interval '7 days'),
    ('33330000-0000-0000-0000-000000000000', 'aaaaaaaa-0000-0000-0000-000000000000',
     'dee@example.com', 'STALECODE', '11111111-1111-1111-1111-111111111111', now() - interval '1 day');

set local request.jwt.claims = '{"sub":"44444444-4444-4444-4444-444444444444"}';
set local role authenticated;

do $$
begin
    begin
        perform accept_invite('WRONGPERSON');
        raise exception 'a code issued to another address must not work';
    exception when raise_exception then
        if sqlerrm = 'a code issued to another address must not work' then raise; end if;
    end;

    begin
        perform accept_invite('STALECODE');
        raise exception 'an expired code must not work';
    exception when raise_exception then
        if sqlerrm = 'an expired code must not work' then raise; end if;
    end;

    assert accept_invite('GOODCODE') = 'aaaaaaaa-0000-0000-0000-000000000000',
        'the right code joins the org';
    assert (select count(*) from org_members) = 4, 'Dee is now on the roster';
    assert not exists (select 1 from invites),
        'the invite list is the owner''s; redeeming a code does not open it';

    -- Joining is what puts you on the board; Dee has dictated nothing yet.
    assert exists (select 1 from leaderboard where display_name = 'Ada'),
        'a new member sees the team board';
    assert not exists (select 1 from leaderboard where display_name = 'Dee'),
        'a member with no dictations has no row yet';
end $$;

reset role;

do $$
begin
    assert (select accepted_by from invites where code = 'GOODCODE')
           = '44444444-4444-4444-4444-444444444444', 'the invite records who used it';
    assert (select accepted_at from invites where code = 'GOODCODE') is not null,
        'a redeemed invite is marked used and cannot be replayed';
    assert (select accepted_at from invites where code = 'WRONGPERSON') is null,
        'a rejected code stays unused';
end $$;

rollback;
