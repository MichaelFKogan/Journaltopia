-- Undoes the storage.objects rename performed by 20260819000000, which broke every sample asset.
--
-- What went wrong
-- ---------------
-- 20260819000000 moved deployed state onto the Journaltopia names. For the database that was
-- correct: sample_storyboard_pages.storage_path and sample_entry_assets.storage_path are ordinary
-- text columns and a regexp_replace is exactly the right tool. It then applied the same treatment to
-- the storage metadata:
--
--     update storage.objects
--     set name = regexp_replace(name, '^storytopia-first-run/', 'journaltopia-first-run/')
--     where bucket_id = 'sample-story-assets' and name like 'storytopia-first-run/%';
--
-- storage.objects is not a path column. It is the index over an object store, and the bytes live
-- under a key derived from `bucket_id/name/version`. Renaming the row does not move the object, so
-- the row and the bytes stop pointing at each other: the row is found, the fetch behind it is not.
-- Every read 404s with NoSuchKey while `list` keeps reporting the file, correct size and eTag and
-- all, which is what makes this look like a permissions problem when it is not one.
--
-- All 35 objects in sample-story-assets were affected — the entire signed-out sample pack, which is
-- why the storyboards render as the offline placeholder on Entries and Profile.
--
-- What this migration does
-- ------------------------
-- Puts the names back so the rows agree with the bytes again. That alone restores every sample
-- image, because the app reads storage_path from the sample tables and those columns are corrected
-- to match below.
--
-- Renaming the objects *properly* is a separate, optional step and cannot be done in SQL at all: it
-- has to go through the Storage API, which copies the bytes to the new key before it updates the
-- row. supabase/scripts/repair_sample_storage_paths.py does that and re-points the sample tables
-- when it finishes. Until it is run the pack simply lives under its original prefix, which costs
-- nothing but tidiness.
--
-- The guard below is what keeps this migration safe to apply more than once, and safe on a database
-- that never carried the bad state — a fresh `db reset` builds an empty bucket, matches nothing, and
-- moves on.

update storage.objects
set name = regexp_replace(name, '^journaltopia-first-run/', 'storytopia-first-run/')
where bucket_id = 'sample-story-assets'
  and name like 'journaltopia-first-run/%';

-- The two path columns follow the objects. They were renamed correctly by 20260819000000 and are
-- being walked back only because the objects they address could not follow them.
update public.sample_storyboard_pages
set storage_path = regexp_replace(storage_path, '^journaltopia-first-run/', 'storytopia-first-run/')
where storage_path like 'journaltopia-first-run/%';

update public.sample_entry_assets
set storage_path = regexp_replace(storage_path, '^journaltopia-first-run/', 'storytopia-first-run/')
where storage_path like 'journaltopia-first-run/%';

-- sample_journals.cover_storage_path is deliberately absent. 20260819000000 renamed the storyboard
-- and asset path columns but not this one, so the covers were left addressing
-- `storytopia-first-run/journals/…` while their objects were renamed out from under them — the same
-- break as everything else here, arrived at from the opposite direction. Restoring the object names
-- above is what repairs them; rewriting the column too would break them again.

-- Note for whoever renames this pack next: the prefix is written by SupabaseSampleStoryService's
-- `authoringPackSlug`, so newly authored assets land under `journaltopia-first-run/` while the
-- existing ones are back under `storytopia-first-run/`. Mixed prefixes are harmless — every read
-- resolves the path out of the database rather than deriving it — but running the repair script is
-- what collapses them back to one.
