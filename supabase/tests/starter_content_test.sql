-- Starter content for new accounts: what gets created, and that it is created exactly once.
--
-- Run with: supabase test db   (requires the local Supabase stack)
--
-- The properties worth pinning here are the ones whose failure is invisible in the app. Seeding
-- twice looks like a user who mysteriously has eight journals. Seeding an account that deleted its
-- starter journals looks like content that will not stay deleted. A template table readable by
-- `authenticated` looks like nothing at all until someone notices unreleased copy in a network log.

create extension if not exists pgtap with schema extensions;

begin;

select plan(31);

-- Signing up ---------------------------------------------------------------------------------------
-- The only fixture is an auth.users row, because that is the only thing a real signup creates. The
-- profile, the journals, the entry and its membership all come from the trigger.
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at)
values (
    '00000000-0000-0000-0000-000000000000', 'aaaa0000-0000-4000-8000-000000000001',
    'authenticated', 'authenticated', 'starter-one@example.com', 'x', now(), now()
);

select is(
    (select count(*)::int from public.journals where user_id = 'aaaa0000-0000-4000-8000-000000000001'),
    4,
    'a new account gets four starter journals'
);

select is(
    (
        select array_agg(title order by display_order)
        from public.journals
        where user_id = 'aaaa0000-0000-4000-8000-000000000001'
    ),
    array['Everyday Stories', 'Summer Adventures', 'Dream Log', 'People & Places'],
    'the journals arrive in the order the templates set'
);

select is(
    (
        select cover_image_name
        from public.journals
        where user_id = 'aaaa0000-0000-4000-8000-000000000001'
          and title = 'Everyday Stories'
    ),
    'IMG_9080',
    'covers are bundled asset names, so no storage work is involved'
);

select is(
    (select count(*)::int from public.entries where user_id = 'aaaa0000-0000-4000-8000-000000000001'),
    1,
    'a new account gets one starter entry'
);

select is(
    (select title from public.entries where user_id = 'aaaa0000-0000-4000-8000-000000000001'),
    'Welcome to Journaltopia',
    'the starter entry is the welcome entry'
);

select is(
    (select status from public.entries where user_id = 'aaaa0000-0000-4000-8000-000000000001'),
    'draft',
    'the starter entry is a draft, since nothing has been illustrated for it'
);

-- Membership ---------------------------------------------------------------------------------------
-- `journal_entries` keys off `client_entry_id`, not `entries.id`. A seed that filled in the wrong one
-- would fail the foreign key rather than mis-file the entry, but the join is asserted anyway because
-- it is the thing the Journals tab actually reads.
select is(
    (
        select j.title
        from public.journal_entries je
        join public.journals j
            on j.user_id = je.user_id and j.id = je.journal_id
        where je.user_id = 'aaaa0000-0000-4000-8000-000000000001'
    ),
    'Everyday Stories',
    'the starter entry is filed in the journal its template names'
);

select is(
    (
        select count(*)::int
        from public.journal_entries je
        join public.entries e
            on e.user_id = je.user_id and e.client_entry_id = je.client_entry_id
        where je.user_id = 'aaaa0000-0000-4000-8000-000000000001'
    ),
    1,
    'the membership resolves to the entry that was created for it'
);

select ok(
    (
        select starter_content_seeded_at is not null
        from public.profiles
        where id = 'aaaa0000-0000-4000-8000-000000000001'
    ),
    'the account is marked as seeded'
);

-- Once per account ---------------------------------------------------------------------------------
select is(
    public.seed_starter_content('aaaa0000-0000-4000-8000-000000000001'),
    false,
    'a second call declines to seed an account that is already marked'
);

select is(
    (select count(*)::int from public.journals where user_id = 'aaaa0000-0000-4000-8000-000000000001'),
    4,
    'and creates nothing on the way to declining'
);

-- Deleting starter content is permanent -------------------------------------------------------------
-- The marker outlives the rows on purpose. A user who clears out the journals we gave them has made
-- a decision, and the next call must respect it rather than reading an empty account as a new one.
delete from public.journals where user_id = 'aaaa0000-0000-4000-8000-000000000001';
delete from public.entries  where user_id = 'aaaa0000-0000-4000-8000-000000000001';

select is(
    public.seed_starter_content('aaaa0000-0000-4000-8000-000000000001'),
    false,
    'an account that deleted its starter content is not re-seeded'
);

select is(
    (select count(*)::int from public.journals where user_id = 'aaaa0000-0000-4000-8000-000000000001'),
    0,
    'the deleted journals stay deleted'
);

select is(
    public.seed_starter_content('aaaa0000-0000-4000-8000-00000000dead'),
    false,
    'seeding an account that has no profile does nothing rather than erroring'
);

-- Inactive templates ---------------------------------------------------------------------------------
-- `is_active` is the retirement switch: it takes a journal out of future signups without deleting
-- the copy, and without touching the accounts that already have it.
update public.starter_journal_templates set is_active = false where slug = 'dream-log';

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at)
values (
    '00000000-0000-0000-0000-000000000000', 'aaaa0000-0000-4000-8000-000000000002',
    'authenticated', 'authenticated', 'starter-two@example.com', 'x', now(), now()
);

select is(
    (select count(*)::int from public.journals where user_id = 'aaaa0000-0000-4000-8000-000000000002'),
    3,
    'a retired template is skipped for accounts created after it was retired'
);

select is(
    (
        select count(*)::int
        from public.journals
        where user_id = 'aaaa0000-0000-4000-8000-000000000002' and title = 'Dream Log'
    ),
    0,
    'and it is the retired journal that is missing'
);

-- Nothing here is client-reachable ------------------------------------------------------------------
-- The templates hold unreleased copy and the function writes rows on someone's behalf. Neither is a
-- Data API surface, and Postgres grants EXECUTE to PUBLIC by default, so the revoke is asserted
-- rather than assumed.
select ok(
    not has_function_privilege('authenticated', 'public.seed_starter_content(uuid)', 'execute'),
    'a signed-in client cannot call the seeder'
);

select ok(
    not has_table_privilege('authenticated', 'public.starter_journal_templates', 'select'),
    'a signed-in client cannot read the journal templates'
);

select ok(
    not has_table_privilege('anon', 'public.starter_entry_templates', 'select'),
    'a signed-out client cannot read the entry templates'
);

-- Recovering from a failed seed ---------------------------------------------------------------------
-- Signup swallows a seeding failure so it cannot break the signup itself, which means something has
-- to look again later. These assertions cover what that sweep may and may not touch — the "may not"
-- half being the more important one, since a sweep that is too eager re-seeds accounts that made a
-- deliberate choice to be empty.
select ok(
    (
        select starter_content_eligible_at is not null
        from public.profiles
        where id = 'aaaa0000-0000-4000-8000-000000000002'
    ),
    'signup stamps eligibility, whether or not seeding went on to succeed'
);

select is(
    public.sweep_unseeded_starter_content(),
    0,
    'a sweep with nothing pending seeds nobody'
);

-- The exact state a failed seed leaves behind: eligibility stamped by the profile insert, the seeding
-- marker rolled back with the partial rows by the exception block.
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at)
values (
    '00000000-0000-0000-0000-000000000000', 'aaaa0000-0000-4000-8000-000000000003',
    'authenticated', 'authenticated', 'starter-three@example.com', 'x', now(), now()
);

delete from public.journals where user_id = 'aaaa0000-0000-4000-8000-000000000003';
delete from public.entries  where user_id = 'aaaa0000-0000-4000-8000-000000000003';
update public.profiles
set starter_content_seeded_at = null
where id = 'aaaa0000-0000-4000-8000-000000000003';

select is(
    public.sweep_unseeded_starter_content(),
    1,
    'a sweep picks up the account whose seeding failed'
);

select is(
    (select count(*)::int from public.journals where user_id = 'aaaa0000-0000-4000-8000-000000000003'),
    3,
    'and the retry creates the journals that were missed'
);

select is(
    (select count(*)::int from public.entries where user_id = 'aaaa0000-0000-4000-8000-000000000003'),
    1,
    'and the entry that was missed'
);

select ok(
    (
        select starter_content_seeded_at is not null
        from public.profiles
        where id = 'aaaa0000-0000-4000-8000-000000000003'
    ),
    'the retried account is marked, so the next sweep passes over it'
);

select is(
    public.sweep_unseeded_starter_content(),
    0,
    'the next sweep finds nothing left to do'
);

-- The account from earlier that deleted everything we gave it. It is marked seeded, so no sweep may
-- bring the journals back. This is the assertion that keeps the sweeper from overriding a user.
select is(
    (select count(*)::int from public.journals where user_id = 'aaaa0000-0000-4000-8000-000000000001'),
    0,
    'an account that deleted its starter content is not re-seeded by a sweep'
);

-- An account older than the feature. Null eligibility is the whole reason the sweep does not read
-- `starter_content_seeded_at is null` on its own: every pre-existing account matches that.
update public.profiles
set starter_content_eligible_at = null, starter_content_seeded_at = null
where id = 'aaaa0000-0000-4000-8000-000000000002';

delete from public.journals where user_id = 'aaaa0000-0000-4000-8000-000000000002';

select is(
    public.sweep_unseeded_starter_content(),
    0,
    'an account that predates starter content is never swept'
);

select is(
    (select count(*)::int from public.journals where user_id = 'aaaa0000-0000-4000-8000-000000000002'),
    0,
    'and stays exactly as empty as it was'
);

select ok(
    not has_function_privilege('authenticated', 'public.sweep_unseeded_starter_content(integer)', 'execute'),
    'a signed-in client cannot run the sweeper'
);

-- The schedule ---------------------------------------------------------------------------------------
select case
    when to_regclass('cron.job') is null
        then skip('pg_cron is not installed in this database', 1)
    else is(
        (select count(*)::int from public.verify_starter_content_sweeper() where not passed),
        0,
        'every sweeper schedule check passes'
    )
end;

select * from finish();

rollback;
