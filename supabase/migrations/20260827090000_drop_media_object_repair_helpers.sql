-- Removes the repair helpers added by 20260826090000. The recovery is complete.
--
-- What they were for
-- ------------------
-- 20260819000000 rewrote `storage.objects.bucket_id` in SQL to rename the media bucket. The bytes
-- live under a key derived from `bucket_id/name/version`, so the rows moved and the payloads did
-- not: all 86 objects in journaltopia-media listed correctly and 404'd with NoSuchKey. Recovery
-- needed one thing SQL can do and the Storage API cannot — put a row back on the bucket its bytes
-- are keyed under — and one thing only the Storage API can do: move the bytes. park_media_object
-- and unpark_media_object were the first half; media_object_inventory took the pre-repair snapshot,
-- because PostgREST cannot select storage.objects directly.
--
-- All 86 objects were relocated through the Storage API and verified readable, and the recovered
-- images were confirmed in the app. The helpers have no remaining purpose, and park_media_object in
-- particular is not a function to leave lying around: it can hide any object from the application by
-- parking it on a bucket nothing reads. It was service_role only, but the smaller reason to drop it
-- is that it is unused and the larger one is that it is a capability.
--
-- supabase/scripts/repair_media_bucket_paths.py stays in the tree as the record of how the recovery
-- was performed. It will not run against this database any more; its header says so, and says to
-- re-apply 20260826090000 if it is ever needed again.
--
-- What is deliberately NOT dropped
-- --------------------------------
-- The storytopia-media bucket and the objects in it. The repair ran with `--strategy copy`, so each
-- recovered object still has its original row and payload there. That is the backup, and it is
-- staying until there is a reason to be confident it is redundant — which is a decision to make
-- deliberately, with the app verified over time, not as a footnote to a cleanup migration.
-- 20260824090000 already sweeps that bucket during account deletion, so retaining it does not leave
-- a deleted user's files behind.

drop function if exists public.park_media_object(text);
drop function if exists public.unpark_media_object(text);
drop function if exists public.media_object_inventory();
