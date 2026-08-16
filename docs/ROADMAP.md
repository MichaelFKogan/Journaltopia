# Journaltopia — Path to Launch

Ordered so that each phase unblocks the next. Phases 0–4 are release-blocking. Phases 5–7 are polish and can slip.

Companion file: [CURSOR_PROMPTS.md](CURSOR_PROMPTS.md) — copy-paste prompts for each item below.

---

## Where things live

```
Storytopia/
├── StorytopiaApp.swift              App entry, URL handling for auth callback
├── ContentView.swift                Tab shell, sample-author-mode wiring (:31, :168)
├── Models/
│   └── StoryModels.swift            Drafts, storyboards, characters, credits enums
│                                    ├─ OpenAITestConfig.apiKey        (:377)  ← API key read from Info.plist
│                                    ├─ OpenAIImageGenerationQuality   (:394)  ← credit cost per quality
│                                    ├─ CreateEntryDraftStore          (:527)  ← local draft persistence
│                                    └─ GeneratedStoryboardStore       (:1240) ← local storyboard cache
├── Services/
│   ├── OpenAIImageGenerationService.swift      Direct OpenAI calls (to be replaced by Edge Function)
│   ├── OpenAIImageGenerationServiceOld.swift   Dead code — delete
│   └── Supabase/
│       ├── SupabaseConfig.swift                Client + config reads
│       ├── SupabaseAuthService.swift           SupabaseAuthStore: signIn/signOut/status
│       ├── EntrySaveService.swift              Save + thumbnails + SupabaseStoryboardService
│       │                                       └─ deleteStoryboards (:415, :463)
│       ├── SupabaseEntryRepository.swift        Entry + journal CRUD
│       ├── SupabaseReferencePhotoService.swift  Reference photos + character library
│       ├── StoryboardDeletionService.swift      Shared delete/promote/demote rules
│       ├── GenerationCreditService.swift        Credit balance, spend, refund
│       └── SupabaseSampleStoryService.swift     Sample author mode content
├── Views/
│   ├── Components/
│   │   ├── LinedTextEditor.swift    Notebook text editor (100KB)
│   │   └── SharedViews.swift        Paper asset name (:6), art style thumb (:80)
│   └── Pages/
│       ├── CreateEntryView.swift    (487KB) The create/edit screen
│       │   ├─ PaperStyle enum               (:1261)
│       │   ├─ artStyles array               (:1696)  ← art style list lives HERE
│       │   ├─ startStoryboardGeneration()   (:2561)
│       │   ├─ AddToJournalSheet             (:10173)
│       │   ├─ ReusableCharactersSheet       (:11873)
│       │   └─ CharacterEditorSheet          (:12034)
│       ├── JournalView.swift        (766KB) Journals, entry viewer, Media tab (:15022+)
│       ├── ProfileView.swift        Storyboard grid
│       ├── HomeView.swift           Home cards
│       ├── SettingsView.swift       Sample author toggle (:282)
│       └── GenerationCreditsView.swift  Credit UI
└── Config/Supabase.xcconfig         gitignored — holds SUPABASE_* and OPENAI_API_KEY

supabase/
├── functions/unsplash-cover/index.ts   Only Edge Function today
└── migrations/                          25 migrations, latest 20260815170000
```

**Two files hold most of the app.** `CreateEntryView.swift` (487KB) and `JournalView.swift` (766KB) are large enough that Cursor will struggle to hold either in context. Every prompt below names line numbers so you can point Cursor at a region instead of the whole file. Consider a Phase 5 task to split them.

---

## Phase 0 — Secure the API key + server-side generation

**Do this first.** It is the only truly blocking item and it changes the shape of everything else.

Right now `OPENAI_API_KEY` is injected into the app's Info.plist via `Config/Supabase.xcconfig` and read at `StoryModels.swift:379`. The file is gitignored so it is not in your repo history — good — but **anything in Info.plist ships inside the app bundle and can be extracted from an installed app in about a minute.** Once you're on TestFlight or the App Store, that key is public and billable to you.

1. **Build a `generate-storyboard` Supabase Edge Function.** It holds the OpenAI key as a Supabase secret, verifies the caller's JWT, and calls OpenAI. The app never sees the key.
2. **Rotate the OpenAI key** at platform.openai.com once the function is live. The current one has been sitting in a plaintext file on disk; treat it as compromised and revoke it.
3. **Make generation survive app close.** This is the same change, not a separate one. As long as the app makes the OpenAI call itself, backgrounding kills it — iOS gives you ~30 seconds. The fix is: the app POSTs a generation *request*, the function writes an `entry_storyboards` row with `generation_status = 'pending'` and returns immediately, a background worker does the OpenAI call and uploads the image, and the app polls or subscribes to that row. You already have `generation_status` on the table, so the schema is half there.
4. **Move credit spend into the same function.** Today the client calls `spend_generation_credit` and then calls OpenAI. If the app dies between the two, you've charged a credit for nothing. Reserve and refund on the server, in the same transaction as the request row.
5. **Delete `OpenAIImageGenerationServiceOld.swift`.** Dead code with the same key-handling pattern.

Why first: it dictates how the generation UI, the credit system, and the retry logic are all written. Doing credits or retry before this means writing them twice.

---

## Phase 1 — Bug sweep: state bleeding between screens

Cheap fixes, and they make everything after this testable. Right now you can't trust what you're looking at when you test.

- **Opening a pre-made entry then opening Create shows the pre-made entry.** You listed this twice — it's your most-hit bug. `CreateEntryView` isn't clearing `activeDraftID` when entered fresh from the tab bar vs. from an entry tap. See `resolvedCurrentEntryStatus()` at `CreateEntryView.swift:2550` and `clearEditor()` at `:3832`.
- **"Mike" appears in My Characters in Sample Author Mode.** The character library query isn't scoped by authoring mode. `SupabaseReferencePhotoService.swift`, character library section.
- **Add To Journal sheet shows all mfkogan journals in Sample Author Mode.** Same class of bug: `AddToJournalSheet` (`CreateEntryView.swift:10173`) loads user journals regardless of mode.
- **Sample Stories journal shows a purple-color check when its cover is a storyboard image.** Cover-source state isn't mutually exclusive in the journal cover picker.

Do all four in one pass — they're the same root cause (mode/identity not threaded through a query or a state reset).

---

## Phase 2 — Save reliability

- **Automatic retry on save.** Wrap the Supabase writes in `EntrySaveService` with bounded exponential-backoff retry for transient failures (network, 5xx, timeout) — never for auth or validation errors. Surface a persistent "unsaved changes" state rather than a toast that disappears.
- **Verify: does Generate Storyboard save first?** It does — `startStoryboardGeneration()` calls `makeEntryDraftSavePayload(forceSave: true)` at `CreateEntryView.swift:2577` before anything else. Confirm the cloud round-trip actually completes (not just the local draft) and then cross this off.
- **The "don't forget to save" problem.** Two ways to go:
  - *Add the nag:* a save button that pins above the mic on any change, plus disclaimer text.
  - *Remove the problem:* autosave the draft on a debounce, so Save becomes "publish/finish."

  Autosave is the better product and roughly the same work, since `CreateEntryDraftStore` already persists locally. Recommend autosave; keep an explicit Save for the cloud commit.

---

## Phase 3 — Account lifecycle

This is one connected design problem, so answer it as a whole before writing code.

**Recommended flow:**

```
Launch (first ever)
  └─ Onboarding carousel (3–4 swipe pages, no account required)
       └─ Sample Stories, browsable signed out ← you already have sample content
            └─ Tap "Create" or any gated action
                 └─ Sign-in wall (Google + Apple)
                      └─ Grant 25 free credits
                           └─ Paywall appears only when credits run out
```

Sign in late, subscribe later still. Making people sign in before they've seen a storyboard is the single biggest drop-off you can build.

Order of work:

1. **Define the signed-out state.** `authStore.status == .signedOut` already exists (`SupabaseAuthService.swift`). Every tab needs a defined signed-out appearance — right now `HomeView.swift:67` and `ProfileView.swift:367` fall back to sample content, which is a good default. Audit Create and Journals for the same.
2. **Build the First Sign-In view.** Sign out and work through the app cold; that's the only way to find what's broken.
3. **Sign Out must clear the app.** Journals, entries, drafts, cached storyboards, credit balance. `signOut()` clears `StorytopiaLocalAccountScope` and the user, but local stores (`CreateEntryDraftStore`, `GeneratedStoryboardStore`, `SupabaseStorageImageCache`) are not purged — the next user sees the last user's content. **This is a privacy bug, not a polish item.**
4. **Onboarding swipe flow.** A `TabView(.page)` with 3–4 pages, gated on an `@AppStorage` flag. Do it last in this phase; it's the easiest piece and it needs the rest to exist first.
5. **Add Apple Sign In.** Google-only is an App Store review risk when you offer any third-party sign-in.

---

## Phase 4 — Credits and monetization

Depends on Phase 0 (server-side spend) and Phase 3 (a real account lifecycle).

- **Monthly 25-credit grant.** Add `credits_reset_at` to `profiles` and a `grant_monthly_credits` RPC that tops up to 25 when a month has passed. Call it on app foreground; enforce it server-side in the generation function.
- **Buy-credit options.** StoreKit 2 consumable IAPs. The purchase must be verified server-side (an Edge Function that validates the App Store transaction and increments the balance) — never grant credits from a client-side "purchase succeeded."
- **Paywall placement.** Show it when a generation is attempted with an insufficient balance. `GenerationCreditsView.swift` is the natural host.
- **Existing state:** default balance is 10 (`20260802090000_add_generation_credits.sql`), and spend/refund RPCs exist. You need grant + purchase.

---

## Phase 5 — Remaining bugs and UI polish

- Reference Photos / Characters labels overlay text — needs a shadow or background plate.
- Journal Detail: tapping Media glitches the sheet down (`JournalView.swift:15363–15420`, the section-change handlers).
- Entry Details (Next) page shows a "Current Storyboards" card with only 1 storyboard — decide the threshold, hide at <2 or relabel.
- Add To Journal (top-of-page carrot) doesn't save when the entry is unsaved — save the draft first, then attach.
- Saving an unedited entry to a journal does nothing — either make Save always attach, or disable it with a reason.
- De-selecting an entry from its own journal — define the behavior (recommend: an entry may be journal-less; it stays in Entries).
- Media tab: tapping an image with a purple count only shows that entry's images. Add an "Open All" toggle, or make the viewer default to all journal media (`JournalView.swift:16434+`).
- **Answered:** deleting an entry *does* delete the storyboard images from storage and DB (`EntrySaveService.swift:1001` → `deleteStoryboards(clientEntryID:)` at `:463` → storage `.remove` at `:434`). One gap: if any step throws, the sequence aborts and leaves orphans. Make the deletion sequence resilient — continue past a failed sub-delete and log it.
- Consider splitting `CreateEntryView.swift` and `JournalView.swift` into feature folders. They're past the point where any tool — or you in six months — can work in them comfortably.

---

## Phase 6 — Art and content

- **Art styles live at `CreateEntryView.swift:1696`** — a plain `let artStyles = ["Anime", "Graphic Novel", "Pixel Art", "Manga", "Pop Art"]`. Style names are passed straight through to the prompt builder. To add or tune a style, promote this to an enum with an id, display name, thumbnail asset, and prompt fragment, then tune the fragments. That refactor is a prerequisite for everything else in this phase.
- Better anime styles, and a Lo-fi Anime style — becomes a data change once the enum exists.
- Choose Art Style images should be actual storyboards, not single illustrations — asset swap in `Assets.xcassets/Art Style/`.
- More paper styles — `PaperStyle` enum at `CreateEntryView.swift:1261` + assets in `Assets.xcassets/Paper Style/`.
- **Clothing description on the character sheet.** Worth doing: today clothing is locked to whatever the reference photo shows, which makes multi-entry storytelling rigid. Add an optional free-text `appearance_notes` per character in `CharacterEditorSheet` (`CreateEntryView.swift:12034`), append it to the prompt.
- **Character likeness control.** Move it to the Entry Details page and apply to all characters, as you suspected — per-character likeness didn't work well and one global dial is easier to tune.

---

## Phase 7 — Later

- Comic Reader views: horizontal and vertical scroll modes for "The Story So Far," Journal > Tap To Open, and Profile > Tap To Open.
- Most recent storyboard on the homepage.
- Dates on full-page storyboard views — recommend no; it breaks the comic illusion. Put dates in a detail sheet instead.

---

## Suggested schedule

| Phase | Content | Rough effort |
|---|---|---|
| 0 | Edge Function, key rotation, background generation | 3–5 days |
| 1 | State-bleed bug sweep | 1 day |
| 2 | Save retry + autosave | 1–2 days |
| 3 | Account lifecycle + onboarding | 3–4 days |
| 4 | Credits + IAP | 2–3 days |
| 5 | Bug and UI polish | 2–3 days |
| 6 | Art and content | 2–3 days |
| 7 | Later | — |

Ship after Phase 5. Phase 6 is what makes it good, but Phase 5 is what makes it shippable.
