-- Self-check for the leaderboard math. Seeds fixtures, asserts, rolls back.
-- Run against a database that already has db/schema.sql applied:
--   psql "$WISPR_DATABASE_URL" -v ON_ERROR_STOP=1 -f db/check.sql
-- Silence means every assert passed.

set time zone 'UTC';
begin;

insert into users (id, email, display_name) values
    ('11111111-1111-1111-1111-111111111111', 'a@example.com', 'Ada'),
    ('22222222-2222-2222-2222-222222222222', 'b@example.com', 'Bo'),
    ('33333333-3333-3333-3333-333333333333', 'c@example.com', 'Cy');

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
insert into dictations (id, user_id, org_id, created_at, word_count, duration_seconds, app_name, provider) values
    (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000000', now(),                        300, 120, 'Xcode', 'local'),
    (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'aaaaaaaa-0000-0000-0000-000000000000', now() - interval '1 day',     200,  60, 'Slack', 'local'),
    (gen_random_uuid(), '22222222-2222-2222-2222-222222222222', 'aaaaaaaa-0000-0000-0000-000000000000', now(),                        100,  60, 'Slack', 'local'),
    (gen_random_uuid(), '33333333-3333-3333-3333-333333333333', 'aaaaaaaa-0000-0000-0000-000000000000', now() - interval '10 days',   500, 300, 'Mail',  'local');

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
        'Week wpm must divide total words by total minutes';

    -- All-time keeps everyone.
    select count(*) into row_count from leaderboard where period = 'all';
    assert row_count = 3, 'all-time should list every member, got ' || row_count;

    -- Streaks: consecutive days ending today count, a 10-day-old run does not.
    assert (select day_streak from leaderboard where period = 'all' and display_name = 'Ada') = 2,
        'Ada dictated today and yesterday: streak 2';
    assert (select day_streak from leaderboard where period = 'all' and display_name = 'Bo') = 1,
        'Bo dictated today only: streak 1';
    assert (select day_streak from leaderboard where period = 'all' and display_name = 'Cy') = 0,
        'Cy last dictated 10 days ago: streak 0';

    -- The leaderboard never touches transcript text.
    assert not exists (
        select 1 from information_schema.view_column_usage
        where view_name in ('leaderboard', 'member_days', 'member_streaks')
          and table_name = 'dictation_texts'),
        'no leaderboard view may read dictation_texts';
end $$;

-- Re-pushing a dictation is an upsert on the client-minted id, not a duplicate.
insert into dictations (id, user_id, org_id, created_at, word_count, duration_seconds, provider)
values ('dddddddd-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222',
        'aaaaaaaa-0000-0000-0000-000000000000', now(), 10, 10, 'local');
insert into dictations (id, user_id, org_id, created_at, word_count, duration_seconds, provider)
values ('dddddddd-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222',
        'aaaaaaaa-0000-0000-0000-000000000000', now(), 25, 10, 'local')
on conflict (id) do update set word_count = excluded.word_count,
                               synced_at  = now();

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

-- Deleting a dictation takes its text with it.
delete from dictations where id = 'dddddddd-0000-0000-0000-000000000000';
do $$
begin
    assert not exists (select 1 from dictation_texts
                       where dictation_id = 'dddddddd-0000-0000-0000-000000000000'),
        'dictation_texts must cascade with its dictation';
end $$;

rollback;
