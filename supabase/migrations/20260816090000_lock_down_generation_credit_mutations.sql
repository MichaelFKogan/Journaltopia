-- Closes the two ways a client could still mint its own generation credits.
--
-- Storyboard generation itself was already safe: `reserve_storyboard_generation` spends and inserts
-- in one transaction, and only the server-owned failing transition ever refunds. But two older paths
-- reached `profiles.generation_credits` without going through any of that, and either one made the
-- whole lifecycle moot:
--
--   1. `refund_generation_credit(integer)` — a security definer function that adds a caller-supplied
--      number of credits, with no reservation to match it against and no upper bound. New functions
--      are executable by PUBLIC, and `authenticated` inherits that, so it was reachable as
--      `POST /rest/v1/rpc/refund_generation_credit {"credit_cost": 1000000}`.
--
--   2. A broad UPDATE grant on `public.profiles`. The RLS policy pins the row to `auth.uid()`, which
--      is why this looked safe, but it says nothing about *columns* — so a client could PATCH its own
--      `generation_credits` to any value.
--
-- Both are removed here. The lifecycle's own refund path is untouched: a failed storyboard still
-- refunds exactly once through fail_storyboard_generation -> finish_failed_storyboard_generation.

-- 1. The legacy refund RPC ------------------------------------------------------------------------
-- Superseded by finish_failed_storyboard_generation, which refunds the amount recorded on the row
-- rather than an amount the caller names, and only on the single transition out of a non-terminal
-- state taken under a row lock. Its last client caller (GenerationCreditService.refundCredit) is
-- removed in the same change as this migration, and the generation flow stopped using it when
-- generation moved server-side.
--
-- Dropped rather than merely revoked: a function that can only be called by roles that never call it
-- is a trap for the next person to grant something, and there is nothing here worth keeping.
drop function if exists public.refund_generation_credit(integer);

-- 2. Column-level UPDATE on profiles ---------------------------------------------------------------
-- Same shape as the entry_storyboards lockdown in 20260815190000: take the table-wide grant away,
-- then hand back exactly the columns a client is supposed to own.
--
-- The current profiles schema is id, display_name, avatar_url, created_at, updated_at,
-- generation_credits. Of those:
--
--   display_name, avatar_url   the user's own presentation, theirs to edit
--   id                         the primary key and the RLS anchor; changing it is never valid
--   created_at                 history
--   updated_at                 maintained by the set_profiles_updated_at trigger
--   generation_credits         currency, and the whole point of this migration
--
-- No client code updates a profile today — the only writer was the debug balance reset, removed
-- alongside this migration, and display_name/avatar_url are populated by the handle_new_user trigger
-- at signup. The two presentation columns are granted anyway so that adding profile editing later is
-- a UI change and not a migration.
--
-- updated_at deliberately stays ungranted. Postgres checks UPDATE privileges against the columns
-- named in the statement's SET list; a BEFORE UPDATE trigger writing NEW.updated_at is not checked
-- against the invoking role, so the timestamp trigger keeps working without the grant.
--
-- INSERT needs no equivalent revoke: profiles has no INSERT policy at all, so RLS already refuses
-- every client insert regardless of grants. Rows are created by handle_new_user, which is security
-- definer and unaffected.
revoke update on public.profiles from anon, authenticated;

grant update (display_name, avatar_url) on public.profiles to authenticated;

-- SELECT is untouched on purpose. Reading your own balance is a normal thing for the app to do, and
-- GenerationCreditService.fetchBalance still does exactly that under the existing RLS policy.

-- 3. Direct execution of spend_generation_credit ---------------------------------------------------
-- Spending is not itself an exploit — it only ever decrements — but it is no longer a client-facing
-- operation either. Its one remaining caller is reserve_storyboard_generation, which `perform`s it so
-- that there stays a single place that knows how a credit is taken. That call runs inside a security
-- definer function owned by the same role that owns this one, so it reaches it by ownership rather
-- than through any grant, and revoking the inherited PUBLIC grant cannot break it.
--
-- Removing it from the client surface means the only way to spend a credit is to reserve a
-- generation, which is what makes the reservation the single accounting entry point.
revoke all on function public.spend_generation_credit(integer) from public, anon, authenticated;
