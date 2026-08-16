-- Storyboard generation is no longer one synchronous request. generate-storyboard now reserves the
-- row, answers the client immediately, and finishes the work in the background, so the row has to
-- carry the state of a job rather than the result of a call:
--
--     pending -> processing -> completed | failed
--
-- 'pending' means the row exists and the credit is reserved. 'processing' means the background
-- worker actually claimed it. Only the server writes the terminal states, and only the server
-- refunds, so the timestamps and the refund record live here where both the worker and the stale-job
-- sweeper can see them.

alter table public.entry_storyboards
    add column if not exists generation_error text,
    add column if not exists reserved_credits integer,
    add column if not exists refunded_credits integer,
    add column if not exists processing_started_at timestamptz,
    add column if not exists completed_at timestamptz,
    add column if not exists failed_at timestamptz;

comment on column public.entry_storyboards.generation_error is
    'Safe, user-displayable reason a generation failed. Written only on the transition to failed.';
comment on column public.entry_storyboards.reserved_credits is
    'Credits spent up front for this generation. The refund amount is read from here rather than
     re-derived from generation_quality, so the two can never disagree.';
comment on column public.entry_storyboards.refunded_credits is
    'Credits actually returned for this generation. NULL means no refund has been recorded; a value
     means the single failing transition already handed that many credits back.';
comment on column public.entry_storyboards.processing_started_at is
    'When the background worker claimed the row. The sweeper measures a stuck processing job from
     here, in server time, rather than trusting anything the client reports.';

-- The status check has to learn 'processing' before any row can be written with it.
alter table public.entry_storyboards
    drop constraint if exists entry_storyboards_generation_status_check;

alter table public.entry_storyboards
    add constraint entry_storyboards_generation_status_check
        check (generation_status in ('pending', 'processing', 'completed', 'failed'));

alter table public.entry_storyboards
    drop constraint if exists entry_storyboards_credit_amounts_check;

alter table public.entry_storyboards
    add constraint entry_storyboards_credit_amounts_check
        check (
            (reserved_credits is null or reserved_credits >= 0)
            and (refunded_credits is null or refunded_credits >= 0)
        );

-- Existing rows were written by the synchronous implementation, which recorded the finishing time
-- only in updated_at. Backfilling from it keeps history readable without inventing precision:
-- the row was last touched when it reached its terminal state.
update public.entry_storyboards
set completed_at = updated_at
where generation_status = 'completed'
  and completed_at is null;

update public.entry_storyboards
set failed_at = updated_at
where generation_status = 'failed'
  and failed_at is null;

-- The sweeper only ever looks at unfinished rows, and there are very few of them at any moment.
create index if not exists entry_storyboards_unfinished_idx
    on public.entry_storyboards (generation_status, created_at)
    where generation_status in ('pending', 'processing');
