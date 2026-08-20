-- Account deletion: that deleting the auth user really does take everything with it, that it takes
-- nothing belonging to anybody else, and that the storage sweep `delete-account` runs first can only
-- ever see the account it was given.
--
-- The properties here are the ones whose failure is silent. A table that quietly stopped cascading
-- leaves a deleted person's writing in the database with no account attached to it. An enumeration
-- function that matches one character too few hands one user's private photo paths to another user's
-- deletion. Both look like a successful deletion from the app.
--
-- Run with: supabase test db   (requires the local Supabase stack)

create extension if not exists pgtap with schema extensions;

begin;

select plan(33);

-- Fixtures -----------------------------------------------------------------------------------------
-- Two real signups. Inserting into auth.users is all a signup is, so both accounts arrive with the
-- starter journals and entry the trigger creates — which is exactly the "new user with starter
-- content" case, for free.
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, created_at, updated_at)
values
    ('00000000-0000-0000-0000-000000000000', 'de1e0000-0000-4000-8000-00000000000a',
     'authenticated', 'authenticated', 'delete-me@example.com', 'x', now(), now()),
    ('00000000-0000-0000-0000-000000000000', 'de1e0000-0000-4000-8000-00000000000b',
     'authenticated', 'authenticated', 'keep-me@example.com', 'x', now(), now());

-- A new account is not empty, and that is the point of this first block.
select cmp_ok(
    (select count(*)::int from public.journals where user_id = 'de1e0000-0000-4000-8000-00000000000a'),
    '>', 0,
    'the account to delete starts with starter journals'
);

select cmp_ok(
    (select count(*)::int from public.entries where user_id = 'de1e0000-0000-4000-8000-00000000000a'),
    '>', 0,
    'the account to delete starts with starter entries'
);

select cmp_ok(
    (select count(*)::int from public.journal_entries where user_id = 'de1e0000-0000-4000-8000-00000000000a'),
    '>', 0,
    'the account to delete starts with starter journal memberships'
);

-- Content on top of the starter set: one of everything a user can own, for both accounts, so that
-- "removed" and "left alone" are asserted against the same shapes.
insert into public.entries (id, user_id, client_entry_id, title, content)
values
    ('e0000000-0000-4000-8000-00000000000a', 'de1e0000-0000-4000-8000-00000000000a',
     'c0000000-0000-4000-8000-00000000000a', 'Mine', 'body'),
    ('e0000000-0000-4000-8000-00000000000b', 'de1e0000-0000-4000-8000-00000000000b',
     'c0000000-0000-4000-8000-00000000000b', 'Theirs', 'body');

insert into public.journals (id, user_id, title)
values
    ('50000000-0000-4000-8000-00000000000a', 'de1e0000-0000-4000-8000-00000000000a', 'My Journal'),
    ('50000000-0000-4000-8000-00000000000b', 'de1e0000-0000-4000-8000-00000000000b', 'Their Journal');

insert into public.journal_entries (user_id, journal_id, client_entry_id)
values
    ('de1e0000-0000-4000-8000-00000000000a', '50000000-0000-4000-8000-00000000000a',
     'c0000000-0000-4000-8000-00000000000a'),
    ('de1e0000-0000-4000-8000-00000000000b', '50000000-0000-4000-8000-00000000000b',
     'c0000000-0000-4000-8000-00000000000b');

insert into public.entry_reference_photos
    (id, user_id, entry_id, client_entry_id, storage_path, mime_type, byte_size, width, height, sort_order)
values
    ('a0000000-0000-4000-8000-00000000000a', 'de1e0000-0000-4000-8000-00000000000a',
     'e0000000-0000-4000-8000-00000000000a', 'c0000000-0000-4000-8000-00000000000a',
     'de1e0000-0000-4000-8000-00000000000a/entries/c0/photo.jpg', 'image/jpeg', 10, 8, 8, 0),
    ('a0000000-0000-4000-8000-00000000000b', 'de1e0000-0000-4000-8000-00000000000b',
     'e0000000-0000-4000-8000-00000000000b', 'c0000000-0000-4000-8000-00000000000b',
     'de1e0000-0000-4000-8000-00000000000b/entries/c0/photo.jpg', 'image/jpeg', 10, 8, 8, 0);

insert into public.entry_characters
    (id, user_id, entry_id, client_entry_id, name, role, storage_path, mime_type, byte_size, width, height, sort_order)
values
    ('c1000000-0000-4000-8000-00000000000a', 'de1e0000-0000-4000-8000-00000000000a',
     'e0000000-0000-4000-8000-00000000000a', 'c0000000-0000-4000-8000-00000000000a',
     'Ada', 'mainCharacter', 'de1e0000-0000-4000-8000-00000000000a/characters/1.jpg', 'image/jpeg', 10, 8, 8, 0),
    ('c1000000-0000-4000-8000-00000000000b', 'de1e0000-0000-4000-8000-00000000000b',
     'e0000000-0000-4000-8000-00000000000b', 'c0000000-0000-4000-8000-00000000000b',
     'Bo', 'mainCharacter', 'de1e0000-0000-4000-8000-00000000000b/characters/1.jpg', 'image/jpeg', 10, 8, 8, 0);

insert into public.entry_storyboards (id, user_id, client_entry_id, storage_path)
values
    ('5b000000-0000-4000-8000-00000000000a', 'de1e0000-0000-4000-8000-00000000000a',
     'c0000000-0000-4000-8000-00000000000a', 'de1e0000-0000-4000-8000-00000000000a/sb/1.jpg'),
    ('5b000000-0000-4000-8000-00000000000b', 'de1e0000-0000-4000-8000-00000000000b',
     'c0000000-0000-4000-8000-00000000000b', 'de1e0000-0000-4000-8000-00000000000b/sb/1.jpg');

insert into public.subscriptions
    (user_id, product_id, original_transaction_id, status, current_period_start, current_period_end)
values
    ('de1e0000-0000-4000-8000-00000000000a', 'plus.monthly', 'txn-a', 'active', now(), now() + interval '30 days'),
    ('de1e0000-0000-4000-8000-00000000000b', 'plus.monthly', 'txn-b', 'active', now(), now() + interval '30 days');

insert into public.credit_ledger (user_id, delta, reason, source_id)
values
    ('de1e0000-0000-4000-8000-00000000000a', 10, 'purchased_credit_pack', 'pack-a'),
    ('de1e0000-0000-4000-8000-00000000000b', 10, 'purchased_credit_pack', 'pack-b');

-- Storage objects. Inserted directly because this test is about *which* rows the enumeration picks,
-- not about the bytes; the Edge Function removes them through the Storage API, which is the only
-- thing that drops the payload as well as the row.
insert into storage.objects (bucket_id, name, owner)
values
    ('journaltopia-media',    'de1e0000-0000-4000-8000-00000000000a/entries/c0/photo.jpg', 'de1e0000-0000-4000-8000-00000000000a'),
    ('generated-storyboards', 'de1e0000-0000-4000-8000-00000000000a/sb/1.jpg',             'de1e0000-0000-4000-8000-00000000000a'),
    ('journal-covers',        'de1e0000-0000-4000-8000-00000000000a/cover.jpg',            'de1e0000-0000-4000-8000-00000000000a'),
    ('journaltopia-media',    'de1e0000-0000-4000-8000-00000000000b/entries/c0/photo.jpg', 'de1e0000-0000-4000-8000-00000000000b'),
    -- Two objects that must never be swept for account A:
    --   a name that merely *starts with* A's uid, which a bare prefix match would take;
    ('journaltopia-media',    'de1e0000-0000-4000-8000-00000000000a-other/photo.jpg',      'de1e0000-0000-4000-8000-00000000000b'),
    --   and shared sample content, which belongs to the app rather than to whoever uploaded it.
    ('sample-story-assets',   'journaltopia-first-run/page-1.jpg',                         'de1e0000-0000-4000-8000-00000000000a');

-- The storage sweep -------------------------------------------------------------------------------
-- Everything `delete-account` will remove, and nothing else.
select is(
    (select count(*)::int from public.user_storage_object_names('de1e0000-0000-4000-8000-00000000000a')),
    3,
    'the sweep finds exactly the three objects the account owns'
);

select bag_eq(
    $$ select bucket_id, name from public.user_storage_object_names('de1e0000-0000-4000-8000-00000000000a') $$,
    $$ values
        ('journaltopia-media',    'de1e0000-0000-4000-8000-00000000000a/entries/c0/photo.jpg'),
        ('generated-storyboards', 'de1e0000-0000-4000-8000-00000000000a/sb/1.jpg'),
        ('journal-covers',        'de1e0000-0000-4000-8000-00000000000a/cover.jpg')
    $$,
    'the sweep spans every private bucket and names the objects exactly'
);

select is(
    (select count(*)::int from public.user_storage_object_names('de1e0000-0000-4000-8000-00000000000a')
     where bucket_id = 'sample-story-assets'),
    0,
    'shared sample assets are never swept, whoever uploaded them'
);

select is(
    (select count(*)::int from public.user_storage_object_names('de1e0000-0000-4000-8000-00000000000a')
     where name like '%-other/%'),
    0,
    'a name that merely starts with the uid is not owned by it'
);

select is(
    (select count(*)::int from public.user_storage_object_names('de1e0000-0000-4000-8000-00000000000b')),
    1,
    'the other account sweeps only its own object'
);

-- Authorization -------------------------------------------------------------------------------------
-- The function reads every user's objects as its definer, so the grant is the only thing standing
-- between it and an enumeration of anybody's private paths.
select function_privs_are(
    'public', 'user_storage_object_names', array['uuid'],
    'authenticated', array[]::text[],
    'a signed-in user cannot enumerate storage objects'
);

select function_privs_are(
    'public', 'user_storage_object_names', array['uuid'],
    'anon', array[]::text[],
    'an anonymous caller cannot enumerate storage objects'
);

select function_privs_are(
    'public', 'user_storage_object_names', array['uuid'],
    'service_role', array['EXECUTE'],
    'only the service role can enumerate storage objects'
);

-- Deletion ------------------------------------------------------------------------------------------
-- The single statement the Edge Function's admin call performs.
delete from auth.users where id = 'de1e0000-0000-4000-8000-00000000000a';

select is(
    (select count(*)::int from auth.users where id = 'de1e0000-0000-4000-8000-00000000000a'),
    0,
    'the auth user is gone'
);

-- Everything below is a cascade, not an explicit delete. Each one is asserted separately because
-- each is a separate foreign key that could be changed independently.
select is((select count(*)::int from public.profiles where id = 'de1e0000-0000-4000-8000-00000000000a'),
    0, 'profiles cascades');
select is((select count(*)::int from public.entries where user_id = 'de1e0000-0000-4000-8000-00000000000a'),
    0, 'entries cascades, starter entries included');
select is((select count(*)::int from public.journals where user_id = 'de1e0000-0000-4000-8000-00000000000a'),
    0, 'journals cascades, starter journals included');
select is((select count(*)::int from public.journal_entries where user_id = 'de1e0000-0000-4000-8000-00000000000a'),
    0, 'journal_entries cascades');
select is((select count(*)::int from public.entry_reference_photos where user_id = 'de1e0000-0000-4000-8000-00000000000a'),
    0, 'entry_reference_photos cascades');
select is((select count(*)::int from public.entry_characters where user_id = 'de1e0000-0000-4000-8000-00000000000a'),
    0, 'entry_characters cascades');
select is((select count(*)::int from public.entry_storyboards where user_id = 'de1e0000-0000-4000-8000-00000000000a'),
    0, 'entry_storyboards cascades');
select is((select count(*)::int from public.subscriptions where user_id = 'de1e0000-0000-4000-8000-00000000000a'),
    0, 'subscriptions cascades');
select is((select count(*)::int from public.credit_ledger where user_id = 'de1e0000-0000-4000-8000-00000000000a'),
    0, 'credit_ledger cascades');
select is((select count(*)::int from auth.identities where user_id = 'de1e0000-0000-4000-8000-00000000000a'),
    0, 'auth identities cascade');
select is((select count(*)::int from auth.sessions where user_id = 'de1e0000-0000-4000-8000-00000000000a'),
    0, 'auth sessions cascade');

-- The regression that made deletion fail entirely: `touch_journal_updated_at` fires on the
-- journal_entries cascade and writes to `journals`, and an ordinary trigger function runs as whoever
-- issued the delete. The Admin API issues it as `supabase_auth_admin`, which has no rights in
-- `public`, so the whole delete rolled back and GoTrue reported "Database error deleting user".
-- Definer rights are what let the cascade above complete; this pins them.
select is(
    (select p.prosecdef
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'touch_journal_updated_at'),
    true,
    'the membership touch trigger runs as definer, so a cascade from auth.users can finish'
);

-- The other account -----------------------------------------------------------------------------------
-- The assertion that makes all of the above worth having.
select is((select count(*)::int from auth.users where id = 'de1e0000-0000-4000-8000-00000000000b'),
    1, 'the other account still exists');
select is((select count(*)::int from public.entries where user_id = 'de1e0000-0000-4000-8000-00000000000b'
           and client_entry_id = 'c0000000-0000-4000-8000-00000000000b'),
    1, 'the other account keeps its entry');
select is((select count(*)::int from public.journals
           where user_id = 'de1e0000-0000-4000-8000-00000000000b'
             and id = '50000000-0000-4000-8000-00000000000b'),
    1, 'the other account keeps its journals');
select cmp_ok(
    (select count(*)::int from public.journal_entries where user_id = 'de1e0000-0000-4000-8000-00000000000b'),
    '>', 0,
    'the other account keeps its journal memberships');
select is((select count(*)::int from public.entry_storyboards where user_id = 'de1e0000-0000-4000-8000-00000000000b'),
    1, 'the other account keeps its storyboard row');
select is((select count(*)::int from public.credit_ledger where user_id = 'de1e0000-0000-4000-8000-00000000000b'),
    1, 'the other account keeps its ledger');

-- Shared content is not user content, and a deletion must not erode the app for everyone else.
select cmp_ok(
    (select count(*)::int from public.starter_journal_templates),
    '>', 0,
    'starter templates survive a deletion'
);

-- Retrying ------------------------------------------------------------------------------------------
-- The Edge Function is safe to call twice, and this is why: the second call finds nothing to do
-- rather than something to trip over.
select is(
    (select count(*)::int from public.user_storage_object_names('de1e0000-0000-4000-8000-00000000000a')),
    3,
    'storage objects outlive the auth user, which is why the sweep runs first'
);

select lives_ok(
    $$ delete from auth.users where id = 'de1e0000-0000-4000-8000-00000000000a' $$,
    'deleting an already-deleted account is a no-op rather than an error'
);

select * from finish();

rollback;
