-- Starter content for brand-new accounts.
--
-- A new account currently lands on an empty Entries tab and an empty Journals tab. This gives it
-- four journals and one instructional entry at signup, and — this is the whole design constraint —
-- gives them as *ordinary rows* in `journals`, `entries` and `journal_entries`. There is no
-- `is_starter` column, no marker, nothing the client can branch on. The app cannot tell these apart
-- from something the user typed, which means rename, recolor, reorder, add-to-journal and delete all
-- work through the paths that already exist, and no screen grows a second content mode the way
-- signed-out sample browsing did.
--
-- The copy lives in two template tables rather than inside the function body, so changing a journal
-- title or rewriting the welcome entry is an UPDATE in Studio — no migration, no deploy, and
-- certainly no App Store release. The templates are read only by the seeding function; neither
-- `anon` nor `authenticated` can see them.
--
-- Storage is deliberately out of scope. Journal covers use `cover_image_name`, which the app
-- resolves against a bundled asset catalog, so four illustrated covers cost four strings and zero
-- bytes in a bucket. Entry thumbnails and storyboards live in per-user private buckets that SQL
-- cannot copy into, so the starter entry is text-only for now.


-- 1. Templates ------------------------------------------------------------------------------------
-- Shaped after the columns of `journals` and `entries` that a seeded row actually needs, not after
-- the whole table. Anything omitted is left to the target table's own default, which is what a row
-- the app itself wrote would carry.
--
-- The checks are here on purpose: a template is validated when it is *edited*, so a typo surfaces in
-- Studio rather than at 3am inside somebody's signup. They mirror the constraints on the real tables
-- (`journals_kind_check`, `entries_status_check`, `entries_date_precision_check`,
-- `entries_has_content_check`), so anything that passes here will insert cleanly downstream.
create table if not exists public.starter_journal_templates (
    slug text primary key,
    title text not null,
    subtitle text,
    color_hex text,
    symbol text,
    -- Asset name from the app's bundled "Regular Set" catalog. Valid values today:
    --   IMG_9080, IMG_9144, IMG_2390, 'IMG_2382 2', IMG_9131, IMG_9113, IMG_9127,
    --   IMG_9126, IMG_9114, IMG_9102, 'IMG_2385 2', IMG_9140, IMG_2214
    -- A name that is not in the bundle is not an error anywhere — the cover just falls back to the
    -- journal's color — so this cannot be constrained here without coupling the database to the
    -- asset catalog. Check the spelling when you edit it.
    cover_image_name text,
    kind text not null default 'journal',
    is_favorite boolean not null default false,
    display_order integer not null default 0,
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint starter_journal_templates_kind_check
        check (kind in ('journal', 'storyboard')),
    constraint starter_journal_templates_title_check
        check (nullif(btrim(title), '') is not null)
);

create table if not exists public.starter_entry_templates (
    slug text primary key,
    -- Which starter journal this entry lands in. Null means the entry is created but filed nowhere,
    -- which is a legitimate thing to want; the entry still appears under Entries.
    journal_slug text references public.starter_journal_templates(slug) on delete set null,
    title text not null,
    content text not null,
    status text not null default 'draft',
    date_precision text not null default 'exact',
    saves_draft boolean not null default true,
    is_private boolean not null default false,
    font_choice_raw_value text,
    text_color_index integer,
    text_size double precision,
    paper_style_raw_value text,
    paper_color_index integer,
    text_alignment_raw_value text,
    -- Order within the Entries list, and within the journal, respectively.
    display_order integer not null default 0,
    position integer not null default 0,
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint starter_entry_templates_status_check
        check (status in ('draft', 'completed', 'archived')),
    constraint starter_entry_templates_date_precision_check
        check (date_precision in ('noDate', 'exact', 'dateOnly', 'monthAndYear', 'yearOnly')),
    -- `entries_has_content_check` accepts a row with either a title or a body. Templates are held to
    -- the stricter rule, because a starter entry with no body is not worth creating.
    constraint starter_entry_templates_content_check
        check (
            nullif(btrim(title), '') is not null
            and nullif(btrim(content), '') is not null
        )
);

create index if not exists starter_journal_templates_active_order_idx
    on public.starter_journal_templates (display_order, slug)
    where is_active;

create index if not exists starter_entry_templates_active_order_idx
    on public.starter_entry_templates (display_order, slug)
    where is_active;

drop trigger if exists set_starter_journal_templates_updated_at on public.starter_journal_templates;
create trigger set_starter_journal_templates_updated_at
    before update on public.starter_journal_templates
    for each row
    execute function public.set_updated_at();

drop trigger if exists set_starter_entry_templates_updated_at on public.starter_entry_templates;
create trigger set_starter_entry_templates_updated_at
    before update on public.starter_entry_templates
    for each row
    execute function public.set_updated_at();

-- No client, signed in or out, has any business reading these. RLS on with zero policies denies
-- every row, and withholding the Data API grants means the request is refused before a policy is
-- even consulted. `seed_starter_content` reads them as a security definer and is unaffected by both.
alter table public.starter_journal_templates enable row level security;
alter table public.starter_entry_templates enable row level security;

revoke all on public.starter_journal_templates from anon, authenticated;
revoke all on public.starter_entry_templates   from anon, authenticated;

-- service_role keeps ordinary DML, matching the blanket grant `20260816120000` made to every table
-- that existed then. It is how the copy gets edited from Studio or a trusted script, and the grants
-- test asserts the invariant across the whole schema, so a table left out here fails the suite.
grant select, insert, update, delete on public.starter_journal_templates to service_role;
grant select, insert, update, delete on public.starter_entry_templates   to service_role;


-- 2. Seeding marker -------------------------------------------------------------------------------
-- Account-scoped, because "has this account been seeded?" is a fact about the account and not about
-- the phone in someone's hand. A device-level flag would re-seed on a second device and lose track
-- on a reinstall.
--
-- Existing accounts are left null, which reads as *not seeded*. That is safe: nothing seeds them,
-- because the trigger below only fires for rows newly inserted into auth.users. Backfilling is an
-- explicit, deliberate act — see the note at the bottom of this file.
--
-- `20260816120000` revoked table-level UPDATE on profiles and granted it back per column, so this
-- column is not writable by `authenticated`. Nothing more to do to keep it server-owned.
alter table public.profiles
    add column if not exists starter_content_seeded_at timestamptz;

comment on column public.profiles.starter_content_seeded_at is
    'When starter content was created for this account. Null means never seeded. Set only by public.seed_starter_content().';


-- 3. The seed -------------------------------------------------------------------------------------
create or replace function public.seed_starter_content(target_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    journal_template record;
    entry_template record;
    new_journal_id uuid;
    new_client_entry_id uuid;
    journal_ids_by_slug jsonb := '{}'::jsonb;
begin
    -- The claim and the work happen in one transaction, and the claim comes first.
    --
    -- This single statement is the entire once-per-account guarantee. The UPDATE takes a row lock on
    -- the profile; a second concurrent call blocks on it, re-reads the row once the first commits,
    -- finds the timestamp already set, matches nothing, and returns false. A user who deletes their
    -- starter journals does not get them back, because the marker survives the rows. And if any
    -- insert below fails, the whole transaction rolls back — the marker with it — so the account is
    -- left unseeded and eligible for a retry rather than half-populated and marked done.
    update public.profiles
    set starter_content_seeded_at = now()
    where id = target_user_id
      and starter_content_seeded_at is null;

    if not found then
        return false;
    end if;

    for journal_template in
        select *
        from public.starter_journal_templates
        where is_active
        order by display_order, slug
    loop
        new_journal_id := gen_random_uuid();

        insert into public.journals (
            id,
            user_id,
            title,
            subtitle,
            color_hex,
            symbol,
            cover_image_name,
            kind,
            is_favorite,
            display_order
        )
        values (
            new_journal_id,
            target_user_id,
            journal_template.title,
            journal_template.subtitle,
            journal_template.color_hex,
            journal_template.symbol,
            journal_template.cover_image_name,
            journal_template.kind,
            journal_template.is_favorite,
            journal_template.display_order
        );

        journal_ids_by_slug := journal_ids_by_slug
            || jsonb_build_object(journal_template.slug, new_journal_id);
    end loop;

    for entry_template in
        select *
        from public.starter_entry_templates
        where is_active
        order by display_order, slug
    loop
        new_client_entry_id := gen_random_uuid();

        -- `client_entry_id` is normally minted on the device; here the database mints it. Everything
        -- downstream — journal membership, storyboards, thumbnails — keys off this column rather
        -- than `entries.id`, so generating it now is what lets the row behave like any other.
        insert into public.entries (
            user_id,
            client_entry_id,
            title,
            content,
            status,
            entry_date,
            date_precision,
            saves_draft,
            is_private,
            font_choice_raw_value,
            text_color_index,
            text_size,
            paper_style_raw_value,
            paper_color_index,
            text_alignment_raw_value,
            display_order
        )
        values (
            target_user_id,
            new_client_entry_id,
            entry_template.title,
            entry_template.content,
            entry_template.status,
            now(),
            entry_template.date_precision,
            entry_template.saves_draft,
            entry_template.is_private,
            entry_template.font_choice_raw_value,
            entry_template.text_color_index,
            entry_template.text_size,
            entry_template.paper_style_raw_value,
            entry_template.paper_color_index,
            entry_template.text_alignment_raw_value,
            entry_template.display_order
        );

        -- A template pointing at a journal that is inactive or missing still produces its entry; it
        -- simply lands unfiled rather than failing the signup.
        if entry_template.journal_slug is not null
            and journal_ids_by_slug ? entry_template.journal_slug
        then
            insert into public.journal_entries (
                user_id,
                journal_id,
                client_entry_id,
                position
            )
            values (
                target_user_id,
                (journal_ids_by_slug ->> entry_template.journal_slug)::uuid,
                new_client_entry_id,
                entry_template.position
            );
        end if;
    end loop;

    return true;
end;
$$;

-- Seeding is not a client operation. Postgres grants EXECUTE to PUBLIC on every new function, so
-- that has to be taken away explicitly or `authenticated` could call this over the Data API and
-- re-seed at will. service_role keeps it for backfills run from a trusted context.
revoke all on function public.seed_starter_content(uuid) from public, anon, authenticated;
grant execute on function public.seed_starter_content(uuid) to service_role;


-- 4. The new-user trigger -------------------------------------------------------------------------
-- Unchanged from `20260718000000` apart from the seeding call: same insert, same conflict handling,
-- same columns. It is restated in full rather than patched because `create or replace function`
-- replaces the whole body, and this is now the definition of record.
--
-- This is the one place all three sign-in paths meet. `SupabaseAuthService` creates accounts three
-- different ways — email/password `signUp`, Google OAuth, and Apple `signInWithIdToken` — and every
-- one of them ends in an `auth.users` insert. Seeding here covers all three, and covers any fourth
-- one added later, without a line of Swift.
--
-- The seeding call is wrapped because a failure here would otherwise abort the whole insert and
-- break signup itself. Swallowed to a warning, a bad template costs a new account its starter
-- content and nothing else; the sub-transaction rolls back the marker along with the partial rows,
-- so the account stays eligible for a backfill once the template is fixed. Look for the warning in
-- the Postgres logs.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.profiles (id, display_name, avatar_url)
    values (
        new.id,
        coalesce(
            new.raw_user_meta_data ->> 'full_name',
            new.raw_user_meta_data ->> 'name',
            new.email
        ),
        new.raw_user_meta_data ->> 'avatar_url'
    )
    on conflict (id) do update
    set
        display_name = excluded.display_name,
        avatar_url = excluded.avatar_url,
        updated_at = now();

    begin
        perform public.seed_starter_content(new.id);
    exception
        when others then
            raise warning 'Journaltopia: starter content seeding failed for user %: %', new.id, sqlerrm;
    end;

    return new;
end;
$$;


-- 5. The starter content itself -------------------------------------------------------------------
-- Titles, subtitles, symbols and colors are taken from the prototype journals the app already ships
-- so the first screen a new user sees is in the voice the rest of Journaltopia is written in. The
-- colors are drawn from `JournalColorOption.all`, which means the swatch shows as already-selected
-- when someone opens the cover picker instead of reading as a custom color.
--
-- `on conflict do nothing`: re-running this migration against a database where the copy has since
-- been edited in Studio must not stamp the edits back to these originals.
insert into public.starter_journal_templates
    (slug, title, subtitle, color_hex, symbol, cover_image_name, kind, is_favorite, display_order)
values
    ('everyday-stories', 'Everyday Stories', 'Small moments worth remembering', '#3D2678', 'sparkles',          'IMG_9080', 'journal', false, 0),
    ('summer-adventures', 'Summer Adventures', 'Trips, detours, and sunlit days', '#214D83', 'sun.max.fill',     'IMG_2390', 'journal', false, 1),
    ('dream-log',         'Dream Log',         'Scenes from the edge of sleep',   '#683BA0', 'moon.stars.fill',  'IMG_9131', 'journal', false, 2),
    ('people-and-places', 'People & Places',   'Portraits of a changing city',    '#245C48', 'building.2.fill',  'IMG_9113', 'journal', false, 3)
on conflict (slug) do nothing;

insert into public.starter_entry_templates
    (slug, journal_slug, title, content, status, display_order, position)
values
    (
        'welcome',
        'everyday-stories',
        'Welcome to Journaltopia',
        $body$This is a journal entry — the same kind you'll write from now on. Have a read, then edit it or delete it once you've looked around.

Here's how Journaltopia works:

1. Tap Create to start an entry. Write as much or as little as you like.
2. Pick an art style, then generate a storyboard from what you wrote.
3. Finished stories live in the Journals tab, organized however you want.

A few things worth knowing:

Every entry starts as a draft. Nothing is illustrated until you ask for it.

You can attach photos and characters to an entry to steer how the artwork looks.

Journals are just collections. Rename them, recolor them, reorder them, or delete the ones you don't want — including this one.

Your first story is the hardest one to start. It doesn't have to be about anything in particular.$body$,
        'draft',
        0,
        0
    )
on conflict (slug) do nothing;


-- Backfilling existing accounts -------------------------------------------------------------------
-- Nothing above touches an account that already exists. To seed one deliberately, call the function
-- for it from a trusted context (Studio, or the service role):
--
--     select public.seed_starter_content('<user-uuid>');
--
-- It returns true if it seeded and false if that account was already seeded. To backfill everyone
-- who has never been seeded — read the count first, and mean it:
--
--     select public.seed_starter_content(id)
--     from public.profiles
--     where starter_content_seeded_at is null;
--
-- That query is for accounts that predate starter content and is a deliberate product decision, not
-- a repair. A signup whose seeding *failed* is a different case and needs no manual action:
-- `20260823091000` stamps those accounts as eligible and retries them on a schedule.
