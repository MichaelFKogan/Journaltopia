# Storytopia Sample Story Content

Sample stories live outside user data. They are public/read-only app content that the Entries page can fetch, cache, and render through the same UI used for real entries.

## Storage

Upload sample images to the public `sample-story-assets` bucket.

Recommended paths:

- `packs/<pack-slug>/entries/<entry-slug>/storyboards/page-01.jpg`
- `packs/<pack-slug>/entries/<entry-slug>/storyboards/page-02.jpg`
- `packs/<pack-slug>/entries/<entry-slug>/reference/photo-01.jpg`
- `packs/<pack-slug>/entries/<entry-slug>/characters/<character-slug>.jpg`

## Tables

Use Settings -> Extra -> Sample Studio in the app to author samples through the normal Create Entry flow. Sample Studio writes to these sample tables and uploads images to `sample-story-assets`, not to real user data.

Before using Sample Studio, add your signed-in Supabase account to `sample_story_admins` once:

```sql
insert into public.sample_story_admins (user_id, email)
values ('YOUR_AUTH_USER_ID', 'you@example.com')
on conflict (user_id) do update
set email = excluded.email;
```

You can still create content manually in this order:

1. `sample_story_packs`
2. `sample_journals`
3. `sample_entries`
4. `sample_journal_entries`
5. `sample_storyboard_pages`
6. `sample_entry_assets`

Only one pack per locale should usually have `is_active = true`.

## Entry Control

`sample_entries` controls the mock story:

- `title`
- `body_text`
- `rich_text`
- `status`: `draft` or `completed`
- `location`
- `entry_date`
- `date_precision`: `noDate`, `exact`, `dateOnly`, `monthAndYear`, or `yearOnly`
- `paper_style_raw_value`
- `paper_color_index`
- `text_color_index`
- `text_size`
- `font_choice_raw_value`
- `text_alignment_raw_value`
- `is_bold`
- `is_italic`
- `is_underlined`
- `is_strikethrough`
- `is_highlighted`
- `art_style`
- `onboarding_callouts`
- `display_order`

## Journal Control

`sample_journals` controls the mock Journals page:

- `title`
- `subtitle`
- `color_hex`
- `symbol`
- `cover_image_name`
- `remote_cover`
- `kind`: `journal` or `storyboard`
- `is_favorite`
- `display_order`

`sample_journal_entries` controls which sample entries appear in each sample journal:

- `sample_journal_id`
- `sample_entry_id`
- `position`

## Storyboard Control

`sample_storyboard_pages` controls completed storyboard pages. A sample entry with `status = completed` should have at least one storyboard page, and the primary/first page is used for the Entries card thumbnail.

## User Data Boundary

Do not insert samples into `entries`, `entry_storyboards`, `journals`, or `journal_entries`. The app treats these rows as curated sample content and falls back to bundled samples if the active Supabase pack is unavailable.
