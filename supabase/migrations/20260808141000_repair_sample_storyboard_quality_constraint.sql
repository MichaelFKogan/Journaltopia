alter table public.sample_storyboard_pages
drop constraint if exists sample_storyboard_pages_generation_quality_check;

alter table public.sample_storyboard_pages
add constraint sample_storyboard_pages_generation_quality_check
check (
    generation_quality is null
    or generation_quality in ('low', 'medium', 'standard', 'hd')
);
