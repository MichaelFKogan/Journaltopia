-- The Data API access model: which roles may touch which tables, before RLS narrows it to rows.
--
-- Run with: supabase test db   (requires the local Supabase stack)
--
-- RLS policies and table privileges are two separate gates, and for most of this project's history
-- only the first one was written down. These assertions pin the second, so that a database built
-- from the migrations is reachable in exactly the way the policies assume — and so that a future
-- migration cannot quietly widen a role by granting more than its policies constrain.
--
-- The assertions are catalog reads, which is the same privilege the executor consults at statement
-- time. Where a grant is deliberately withheld, it is asserted false rather than left unmentioned:
-- an absent privilege that nobody checks is indistinguishable from one nobody thought about.

create extension if not exists pgtap with schema extensions;

begin;

select plan(47);

-- Users' own content ------------------------------------------------------------------------------
-- Four policies each, so four privileges each. Checked as a set, since a partial grant here shows up
-- as a feature that half works rather than as an error.
select is(
    bool_and(
        has_table_privilege('authenticated', 'public.' || t, 'select')
        and has_table_privilege('authenticated', 'public.' || t, 'insert')
        and has_table_privilege('authenticated', 'public.' || t, 'update')
        and has_table_privilege('authenticated', 'public.' || t, 'delete')
    ),
    true,
    'a signed-in client has full DML on its own content tables'
)
from unnest(array[
    'entries', 'entry_reference_photos', 'entry_characters', 'journals', 'journal_entries'
]) as t;

-- Spelled out individually as well: the aggregate above says "something is wrong" without saying
-- what, and these are the tables the whole app reads on launch.
select ok(has_table_privilege('authenticated', 'public.entries', 'select'), 'entries are readable');
select ok(has_table_privilege('authenticated', 'public.entries', 'insert'), 'entries are writable');
select ok(has_table_privilege('authenticated', 'public.journals', 'select'), 'journals are readable');
select ok(has_table_privilege('authenticated', 'public.journals', 'insert'), 'journals are writable');
select ok(has_table_privilege('authenticated', 'public.journal_entries', 'select'), 'journal membership is readable');
select ok(has_table_privilege('authenticated', 'public.entry_characters', 'select'), 'entry characters are readable');
select ok(has_table_privilege('authenticated', 'public.entry_reference_photos', 'select'), 'reference photos are readable');

-- None of these tables are reachable signed out. Signed-out browsing reads sample content only.
select is(
    bool_or(has_table_privilege('anon', 'public.' || t, 'select')),
    false,
    'a signed-out visitor cannot read any user content table'
)
from unnest(array[
    'entries', 'entry_reference_photos', 'entry_characters', 'journals', 'journal_entries',
    'entry_storyboards', 'profiles'
]) as t;

-- Profiles ----------------------------------------------------------------------------------------
-- The Phase 1 shape, now with the read half actually granted: readable, updatable only on the two
-- presentation columns, and the balance writable by nobody.
select ok(
    has_table_privilege('authenticated', 'public.profiles', 'select'),
    'a signed-in client can read its own profile through RLS'
);

select ok(
    has_column_privilege('authenticated', 'public.profiles', 'generation_credits', 'select'),
    'the credit balance is readable, which is what GenerationCreditService.fetchBalance needs'
);

select is(
    has_column_privilege('authenticated', 'public.profiles', 'generation_credits', 'update'),
    false,
    'the credit balance is still not writable by a signed-in client'
);

select is(
    has_table_privilege('authenticated', 'public.profiles', 'update'),
    false,
    'profiles has no table-wide UPDATE, so a new column is unwritable until it is granted'
);

select ok(
    has_column_privilege('authenticated', 'public.profiles', 'display_name', 'update'),
    'profile editing keeps display_name'
);

select ok(
    has_column_privilege('authenticated', 'public.profiles', 'avatar_url', 'update'),
    'profile editing keeps avatar_url'
);

select is(
    has_column_privilege('authenticated', 'public.profiles', 'id', 'update'),
    false,
    'a signed-in client may not move its profile to another id'
);

select is(
    has_column_privilege('authenticated', 'public.profiles', 'created_at', 'update'),
    false,
    'a signed-in client may not rewrite when its profile was created'
);

-- No policy covers either, so granting them would be privilege without a constraint.
select is(
    has_table_privilege('authenticated', 'public.profiles', 'insert'),
    false,
    'profiles are created by the signup trigger, not by clients'
);

select is(
    has_table_privilege('authenticated', 'public.profiles', 'delete'),
    false,
    'clients do not delete profile rows'
);

-- Storyboards -------------------------------------------------------------------------------------
-- Reading and deleting are table-level; writing stays column-level exactly as 20260815190000 left
-- it. These four are the regression guard for this migration: adding SELECT and DELETE must not have
-- restored the table-wide INSERT or UPDATE that migration removed.
select ok(
    has_table_privilege('authenticated', 'public.entry_storyboards', 'select'),
    'a signed-in client can read its own storyboards, including ones generated before today'
);

select ok(
    has_table_privilege('authenticated', 'public.entry_storyboards', 'delete'),
    'a signed-in client can delete its own storyboards'
);

select is(
    has_table_privilege('authenticated', 'public.entry_storyboards', 'insert'),
    false,
    'storyboard inserts are still column-restricted rather than table-wide'
);

select is(
    has_table_privilege('authenticated', 'public.entry_storyboards', 'update'),
    false,
    'storyboard updates are still column-restricted rather than table-wide'
);

select is(
    has_column_privilege('authenticated', 'public.entry_storyboards', 'generation_status', 'update'),
    false,
    'a signed-in client still may not move a generation between states'
);

select is(
    has_column_privilege('authenticated', 'public.entry_storyboards', 'reserved_credits', 'insert'),
    false,
    'a signed-in client still may not claim a reservation it never paid'
);

select is(
    has_column_privilege('authenticated', 'public.entry_storyboards', 'refunded_credits', 'update'),
    false,
    'a signed-in client still may not rewrite what it was refunded'
);

select is(
    has_column_privilege('authenticated', 'public.entry_storyboards', 'completed_at', 'update'),
    false,
    'a signed-in client still may not erase the record that a generation finished'
);

select ok(
    has_column_privilege('authenticated', 'public.entry_storyboards', 'is_primary', 'update'),
    'choosing the primary storyboard is still the client its own'
);

select ok(
    has_column_privilege('authenticated', 'public.entry_storyboards', 'storage_path', 'insert'),
    'storyboard duplication can still write its own metadata'
);

-- Sample content ----------------------------------------------------------------------------------
-- The signed-out experience. All six carry a policy `to anon, authenticated`, and the four detail
-- tables resolve their pack through a subquery, so anon needs the parents readable too.
select is(
    bool_and(has_table_privilege('anon', 'public.' || t, 'select')),
    true,
    'a signed-out visitor can read every table the sample browsing policies span'
)
from unnest(array[
    'sample_story_packs', 'sample_entries', 'sample_journals',
    'sample_entry_assets', 'sample_journal_entries', 'sample_storyboard_pages'
]) as t;

select is(
    bool_or(
        has_table_privilege('anon', 'public.' || t, 'insert')
        or has_table_privilege('anon', 'public.' || t, 'update')
        or has_table_privilege('anon', 'public.' || t, 'delete')
    ),
    false,
    'a signed-out visitor cannot write any sample content'
)
from unnest(array[
    'sample_story_packs', 'sample_entries', 'sample_journals',
    'sample_entry_assets', 'sample_journal_entries', 'sample_storyboard_pages'
]) as t;

select is(
    has_table_privilege('anon', 'public.sample_story_admins', 'select'),
    false,
    'the admin roster is not readable signed out'
);

-- Authoring is granted to every signed-in client and narrowed to admins by the policies, which is
-- what the `exists (… from sample_story_admins …)` check in each of them does.
select is(
    bool_and(
        has_table_privilege('authenticated', 'public.' || t, 'select')
        and has_table_privilege('authenticated', 'public.' || t, 'insert')
        and has_table_privilege('authenticated', 'public.' || t, 'update')
        and has_table_privilege('authenticated', 'public.' || t, 'delete')
    ),
    true,
    'Sample Studio authoring reaches the tables its policies cover'
)
from unnest(array[
    'sample_entries', 'sample_journals', 'sample_entry_assets',
    'sample_journal_entries', 'sample_storyboard_pages'
]) as t;

select ok(
    has_table_privilege('authenticated', 'public.sample_story_packs', 'insert'),
    'a sample admin can create a pack'
);

select ok(
    has_table_privilege('authenticated', 'public.sample_story_packs', 'update'),
    'a sample admin can update a pack'
);

-- There is no delete policy on packs, so the privilege would be unusable and is withheld.
select is(
    has_table_privilege('authenticated', 'public.sample_story_packs', 'delete'),
    false,
    'packs have no delete policy, so no delete privilege is granted'
);

-- Readable so the admin subqueries in every authoring policy can resolve; writable by nobody,
-- because membership is granted out of band and the table has only a select policy.
select ok(
    has_table_privilege('authenticated', 'public.sample_story_admins', 'select'),
    'the admin roster is readable, which every authoring policy depends on'
);

select is(
    bool_or(
        has_table_privilege('authenticated', 'public.sample_story_admins', p)
    ),
    false,
    'nobody may write the admin roster through the Data API'
)
from unnest(array['insert', 'update', 'delete']) as p;

-- The server role ---------------------------------------------------------------------------------
-- Catalog-driven checks pass c.oid rather than a concatenated name. has_table_privilege parses a
-- text argument as a table name, and the planner is free to evaluate it before the namespace join
-- has filtered anything — which means building 'public.' || relname for every row of pg_class,
-- including tables that live in auth or storage, and erroring on the first one that has no
-- same-named table in public. The oid overload resolves nothing and cannot misfire.
select is(
    bool_and(
        has_table_privilege('service_role', c.oid, 'select')
        and has_table_privilege('service_role', c.oid, 'insert')
        and has_table_privilege('service_role', c.oid, 'update')
        and has_table_privilege('service_role', c.oid, 'delete')
    ),
    true,
    'the server role has ordinary DML on every application table'
)
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind = 'r'
  -- credit_ledger is the one exception, and it is asserted on its own terms below: history is
  -- append-only for everyone, the server included.
  and c.relname <> 'credit_ledger';

select is(
    has_table_privilege('service_role', 'public.credit_ledger', 'update')
        or has_table_privilege('service_role', 'public.credit_ledger', 'delete'),
    false,
    'not even the server may rewrite or delete credit history through the Data API'
);

select ok(
    has_table_privilege('service_role', 'public.credit_ledger', 'insert'),
    'the server may append to credit history'
);

-- Every table is still row-protected -------------------------------------------------------------
-- Grants are only half the gate. If a future migration adds a table and grants it without enabling
-- RLS, the privileges above become unrestricted, so the invariant is asserted rather than assumed.
select is(
    bool_and(c.relrowsecurity),
    true,
    'every public table still has row level security enabled'
)
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r';

select is(
    count(*)::int,
    0,
    'no public table carries privileges without policies to constrain them'
)
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind = 'r'
  and not exists (
      select 1 from pg_policies p
      where p.schemaname = 'public' and p.tablename = c.relname
  )
  and (
      has_table_privilege('authenticated', c.oid, 'select')
      or has_table_privilege('anon', c.oid, 'select')
  );

-- The generation credit lockdown is unchanged ------------------------------------------------------
-- Restated here because this migration is the most likely thing to undo it by accident: it is the
-- one that hands privileges back to the same roles Phase 1 took them from.
select ok(
    to_regprocedure('public.refund_generation_credit(integer)') is null,
    'the legacy client-callable refund RPC is still gone'
);

select is(
    has_function_privilege('authenticated', 'public.spend_generation_credit(integer)', 'execute'),
    false,
    'a signed-in client still may not spend a credit directly'
);

select is(
    has_function_privilege('authenticated', 'public.fail_storyboard_generation(uuid,text)', 'execute'),
    false,
    'a signed-in client still may not fail a job or trigger its refund'
);

select ok(
    has_function_privilege(
        'authenticated',
        'public.reserve_storyboard_generation(uuid,uuid,text,text,text,text,integer)',
        'execute'
    ),
    'reserving a generation is still the one credit operation a client may perform'
);

select * from finish();

rollback;
