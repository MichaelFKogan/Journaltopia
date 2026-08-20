-- Refresh starter journal copy and covers.
--
-- `20260823090000` already inserted these rows. Editing that file does nothing on a database that
-- has already applied it, and `on conflict (slug) do nothing` is there so a re-run will not overwrite
-- later copy. Change titles and covers here — or with an UPDATE in Studio — and keep the slugs
-- stable so the welcome entry stays filed in the first journal.
--
-- Cover names resolve against the app's bundled asset catalog. The sample-pack names below are
-- valid in addition to the Regular Set IMG_* names listed on `starter_journal_templates`.

update public.starter_journal_templates
set
    title = 'Daily Journal',
    subtitle = 'Small moments worth remembering',
    cover_image_name = 'daily-journal'
where slug = 'everyday-stories';

update public.starter_journal_templates
set
    title = 'Memories',
    subtitle = 'Trips, detours, and sunlit days',
    cover_image_name = 'memories'
where slug = 'summer-adventures';

update public.starter_journal_templates
set
    title = 'My Life',
    subtitle = 'Scenes from the edge of sleep',
    cover_image_name = 'my-life'
where slug = 'dream-log';

update public.starter_journal_templates
set
    title = 'My Life In 5 Years',
    subtitle = 'Portraits of a changing city',
    cover_image_name = 'five-years-from-now'
where slug = 'people-and-places';

update public.starter_entry_templates
set
    content = $body$This is a journal entry - the same kind you'll write from now on. Have a read, then edit it or delete it once you've looked around.

Here's how Journaltopia works:

1. Tap Create to start an entry. Write as much or as little as you like.
2. Add Reference photos and characters to steer how the artwork looks.
3. Tap Next, and pick an art style, then generate a storyboard from what you wrote.
4. Finished artwork appers here. Each journal entry has it's own storyboard. Like a page in a comic book.

A few things worth knowing:

Every entry starts as a draft. Nothing is illustrated until you ask for it.

You can attach photos and characters to an entry to steer how the artwork looks.

Journals are just collections. Rename them, recolor them, reorder them, or delete the ones you don't want, including this one.

Your first story is the hardest one to start. It doesn't have to be about anything in particular.$body$
where slug = 'welcome';
