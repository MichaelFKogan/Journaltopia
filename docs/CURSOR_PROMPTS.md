# Cursor Prompts — Storytopia

Copy one prompt at a time. They're ordered to match [ROADMAP.md](ROADMAP.md).

**Before you start each one:** open the files named in the prompt so they're in Cursor's context. `CreateEntryView.swift` and `JournalView.swift` are too large to attach whole — use the line numbers to jump to the region and select it.

**A rule worth pasting at the top of every prompt:**

> Do not refactor unrelated code. Do not rename existing symbols. Make the smallest change that fixes the described problem, and show me the diff before applying it to more than one file.

---

## Phase 0 — Security and server-side generation

### 0.1 — Build the generate-storyboard Edge Function

```
I need to move OpenAI image generation off the iOS client and into a Supabase Edge Function, because the API key currently ships inside the app bundle and is extractable.

Current state:
- The key is read from Info.plist in Storytopia/Models/StoryModels.swift, enum OpenAITestConfig (~line 377), injected via Config/Supabase.xcconfig.
- Storytopia/Services/OpenAIImageGenerationService.swift makes the OpenAI calls directly, taking apiKey as a parameter.
- Generation starts at CreateEntryView.swift, startStoryboardGeneration() (~line 2561).
- The existing Edge Function supabase/functions/unsplash-cover/index.ts shows the project's conventions — follow them.

Build supabase/functions/generate-storyboard/index.ts that:
1. Verifies the caller's Supabase JWT and rejects unauthenticated requests.
2. Accepts { clientEntryID, prompt, artStyle, quality, referenceImagePaths[] } — reference images by storage path, NOT base64 blobs in the request body.
3. Reserves credits server-side by calling the existing spend_generation_credit RPC as the calling user, before any OpenAI work.
4. Calls the OpenAI image API with the key read from Deno.env.get("OPENAI_API_KEY").
5. Uploads the result to the generated-storyboards bucket using the same storage path convention as SupabaseStoryboardService in EntrySaveService.swift.
6. Inserts/updates the entry_storyboards row, setting generation_status.
7. On any failure after the reservation, calls refund_generation_credit before returning the error.

Then rewrite OpenAIImageGenerationService.swift to call this function via the Supabase client instead of OpenAI, keeping its public method signatures unchanged so CreateEntryView doesn't need to change yet. Remove the apiKey parameter.

Do not delete OpenAITestConfig yet — I'll remove it in a follow-up once this is verified working.
```

After this lands: set the secret with `supabase secrets set OPENAI_API_KEY=...`, deploy, test, **then rotate the key at platform.openai.com and remove `OPENAI_API_KEY` from `Config/Supabase.xcconfig`.**

### 0.2 — Make generation survive app close

```
Storyboard generation currently dies if the user backgrounds the app, because the OpenAI call is an in-flight URLSession task owned by the view.

Convert it to a fire-and-poll model:

1. Change supabase/functions/generate-storyboard/index.ts to return immediately after inserting an entry_storyboards row with generation_status = 'pending', kicking the OpenAI work off with EdgeRuntime.waitUntil() so it completes after the response is sent.
2. In the app, after the request returns, stop awaiting anything. Instead register the pending storyboard id in GeneratedStoryboardStore (StoryModels.swift ~line 1240) so it survives app termination.
3. Add a poll-or-subscribe service that, on app foreground and on app launch, finds every locally-known pending storyboard and checks its generation_status. On 'completed', download the image and update the UI. On 'failed', surface the error and confirm the credit was refunded.
4. Wire it to scenePhase. JournalView.swift ~line 339 already observes scenePhase — follow that pattern rather than inventing a new one.
5. The existing StoryboardGenerationGlobalStatus type (StoryModels.swift ~line 204) drives the generation banner. Make it reflect restored-from-pending state, not just in-session state.

Show me the polling service as a standalone file first before wiring it into the views.
```

### 0.3 — Delete dead code

```
Delete Storytopia/Services/OpenAIImageGenerationServiceOld.swift and remove it from the Xcode project. Confirm nothing references it first.
```

---

## Phase 1 — State-bleed bug sweep

### 1.1 — Create page shows a previously-opened entry

```
Bug: if I open an existing entry from Entries, then tap the Create tab, the Create page still shows the previously opened entry instead of a blank one. It happens with pre-made/sample entries too.

Relevant code in Storytopia/Views/Pages/CreateEntryView.swift:
- resolvedCurrentEntryStatus() ~line 2550
- clearEditor() ~line 3832
- the draft-loading path around loadSavedDraftIfNeeded() ~line 2545
- isOpeningCompletedEntryFromEntries

Trace how activeDraftID is set and when it's cleared. The Create tab entered fresh should always start blank; only an explicit "open this entry" navigation should populate the editor. Find where that distinction is lost and fix it. Tell me the root cause before you change anything.
```

### 1.2 — Sample Author Mode leaks the real account's data

```
Three bugs with one likely root cause: Sample Author Mode is not being threaded through data queries.

1. My Characters shows "Mike" (my real account's character library) while in Sample Author Mode. Character library code is in Storytopia/Services/Supabase/SupabaseReferencePhotoService.swift; the UI is ReusableCharactersSheet in CreateEntryView.swift ~line 11873.
2. The Add To Journal sheet lists all of mfkogan's real journals in Sample Author Mode. AddToJournalSheet is at CreateEntryView.swift ~line 10173.
3. Sample content lives in SupabaseSampleStoryService.swift; the mode flag is isSampleAuthorModeEnabled in ContentView.swift line 31, passed down at lines 168-261.

Find every query that should be mode-aware and isn't. Prefer threading the existing authoringMode value (ContentView.swift ~line 261) through, rather than reading @AppStorage in a dozen new places.
```

### 1.3 — Journal cover shows a color check over an image cover

```
Bug: in Sample Author Mode, the Sample Stories journal shows a checkmark on the purple color swatch in the Journal Covers page even though its cover is actually a storyboard image.

The cover picker is in Storytopia/Views/Pages/JournalView.swift — look for JournalCustomizationSheet (~line 2974) and JournalPageBackgroundSheet (~line 2444).

Cover source (color / image / storyboard) should be a single enum with one selected case, so the color grid shows no checkmark when an image cover is active. Find where color selection and image selection are tracked as independent state and unify them.
```

---

## Phase 2 — Save reliability

### 2.1 — Automatic retry on save

```
Saves to Supabase currently fail permanently on a transient network error.

In Storytopia/Services/Supabase/EntrySaveService.swift, add bounded retry with exponential backoff (3 attempts, ~0.5s/1.5s/4s + jitter) around the network writes.

Requirements:
- Retry ONLY transient failures: URLError network conditions, timeouts, HTTP 5xx, and PostgrestError connection failures.
- Never retry auth failures, validation errors, or 4xx. Those must fail immediately.
- Write it as one reusable helper (e.g. withRetry) rather than duplicating the logic at each call site.
- The local draft must already be persisted before the cloud attempt starts, so a total failure never loses the user's writing.
- On final failure, surface a persistent "not saved" state the UI can show — not a transient error string that gets cleared.

GenerationCreditService.swift has a good example of the project's error-mapping style (GenerationCreditError.mapped). Match it.
```

### 2.2 — Autosave instead of a save nag

```
I want to stop relying on users remembering to press Save.

In Storytopia/Views/Pages/CreateEntryView.swift:
1. Autosave the local draft on a debounce (about 2 seconds after typing stops, plus on backgrounding and on view disappear). CreateEntryDraftStore.save already exists in StoryModels.swift ~line 527 — use it.
2. Keep the explicit Save button, but repurpose it to commit to Supabase, and show a clear state: "Saved", "Saving…", "Saved locally — will sync".
3. Make the button visible above the mic button whenever there are uncommitted cloud changes, instead of hiding it.

Do not change the generation flow — startStoryboardGeneration() already force-saves at line 2577 and that behavior stays.
```

---

## Phase 3 — Account lifecycle

### 3.1 — Sign out must clear all local data (privacy bug)

```
Signing out does not clear locally cached content, so the next person to sign in on the same device can see the previous user's journals and storyboards.

signOut() is in Storytopia/Services/Supabase/SupabaseAuthService.swift. It clears StorytopiaLocalAccountScope and currentUser but nothing else.

Add a single purge routine, called on sign out, that clears:
- CreateEntryDraftStore (StoryModels.swift ~line 527)
- GeneratedStoryboardStore (StoryModels.swift ~line 1240)
- SupabaseStorageImageCache (EntrySaveService.swift)
- EntryLocationRecentStore (StoryModels.swift ~line 459)
- GenerationCreditStore (GenerationCreditService.swift) — it has a reset()
- any @AppStorage keys holding user content

Put the purge in one place that owns the full list, so a future cache can't be forgotten. Verify: sign out, force quit, relaunch — no previous-user content anywhere.
```

### 3.2 — Signed-out experience audit

```
I need every screen to have a defined signed-out state. Right now some fall back to sample content and others I haven't checked.

Storytopia/Services/Supabase/SupabaseAuthService.swift exposes status: .loading / .signedOut / .signedIn / .misconfigured.
HomeView.swift line 67 and ProfileView.swift line 367 already fall back to sample content when signed out — that's the pattern I want.

Audit ContentView.swift, HomeView.swift, JournalView.swift, ProfileView.swift, CreateEntryView.swift, SettingsView.swift and report — as a table, before changing code — what each currently renders when status == .signedOut, and what's broken or empty.

Then: browsing sample content signed out should work everywhere, and any action that requires an account (create, generate, save) should present a sign-in prompt rather than failing or showing an empty screen.
```

### 3.3 — First sign-in / sign-in wall view

```
Build the sign-in screen for Storytopia.

- New file: Storytopia/Views/Pages/SignInView.swift
- Use SupabaseAuthStore from Services/Supabase/SupabaseAuthService.swift (signInWithGoogle already exists).
- Add Sign in with Apple alongside Google — required by App Store review when other third-party sign-in is offered. Wire it through Supabase's signInWithIdToken.
- It must work in two modes: full-screen (first launch after onboarding) and a sheet (presented when a signed-out user taps a gated action).
- Handle .loading and .misconfigured states — misconfigured should show the config error, not a spinner forever.
- Match the app's existing visual language: pull colors and fonts from Extensions/Extensions.swift and Views/Components/SharedViews.swift. Do not introduce new colors.

Show me the view in isolation with a preview first. I'll wire the presentation logic after I see it.
```

### 3.4 — Onboarding carousel

```
Build a first-launch onboarding flow.

- New file: Storytopia/Views/Pages/OnboardingView.swift
- 4 swipeable pages using TabView with .tabViewStyle(.page): what Storytopia is, write your entry, add your characters, get your storyboard.
- Page dots, a Skip control, and a "Get Started" button on the last page.
- Gate it on @AppStorage("StorytopiaHasCompletedOnboarding"). Present from ContentView.swift as a fullScreenCover when false.
- No account required to get through it — it ends by dropping the user into the app browsing sample content, NOT at a sign-in wall.
- Use existing assets from Assets.xcassets (Art Style/ and Storyboard Placeholder/ have usable imagery). Don't add new asset requirements.
```

---

## Phase 4 — Credits and monetization

### 4.1 — Monthly credit grant

```
Add a monthly refresh of free generation credits, 25 per month.

Existing state: supabase/migrations/20260802090000_add_generation_credits.sql adds profiles.generation_credits (default 10) plus spend_generation_credit; 20260815170000 adds refund_generation_credit. Client-side: Storytopia/Services/Supabase/GenerationCreditService.swift.

Write a new migration that:
1. Adds profiles.credits_reset_at timestamptz.
2. Adds a grant_monthly_credits() RPC, security definer, that tops the caller's balance up to 25 if credits_reset_at is null or more than one month ago, sets credits_reset_at = now(), and returns the new balance. It must top UP to 25, not add 25, and must never reduce a balance above 25 (purchased credits must survive).

Then add grantMonthlyCredits() to GenerationCreditService and call it from GenerationCreditStore.refresh(). Follow the existing error-mapping pattern in GenerationCreditError.mapped.
```

### 4.2 — Credit purchase with StoreKit 2

```
Add in-app purchase of generation credits.

1. New file Storytopia/Services/StoreKitService.swift using StoreKit 2: load consumable products, purchase, and listen for Transaction.updates.
2. Credits must be granted SERVER-side only. On a successful purchase, send the signed transaction JWS to a new Edge Function supabase/functions/verify-credit-purchase/index.ts that validates it with Apple, checks the transaction id hasn't already been redeemed (store redeemed ids in a new table), and increments profiles.generation_credits. Never grant credits from the client.
3. Handle interrupted purchases: unfinished transactions must be re-verified on launch, and only finish() after the server confirms.
4. Surface the purchase UI in Storytopia/Views/Pages/GenerationCreditsView.swift, and present it when generation is blocked by an insufficient balance.

Start with the Edge Function and the migration. I'll set up the App Store Connect products separately.
```

---

## Phase 5 — Bugs and polish

### 5.1 — Media tab "Open All"

```
In the Media tab, tapping an image opens a full-screen viewer. If the tapped tile has a purple count badge (an entry with multiple storyboards) the viewer only scrolls that entry's images, but I want the option to scroll all media in the journal.

Code is in Storytopia/Views/Pages/JournalView.swift — the media viewer around line 16434, storyboardsForMedia() ~line 16567, and the tab handling ~lines 15363-15420.

Add a toggle in the viewer ("This entry" / "All media") that switches the scroll scope without closing the viewer, keeping the currently-shown image in place across the switch. Default to the current per-entry behavior.
```

### 5.2 — Media tab sheet glitch

```
Bug: in Journal Detail, tapping the Media tab makes the sheet glitch downward before settling.

Storytopia/Views/Pages/JournalView.swift lines 15363-15420 handle section changes ("Pages" / "Media") with several onChange handlers that react to selectedSection.

Likely cause: a detent or content-height change is applied mid-transition, or state is mutated during a view update. Diagnose it before fixing — tell me which handler causes the jump. Fix it so switching tabs doesn't move the sheet.
```

### 5.3 — Grab-bag UI fixes

```
Four small fixes in Storytopia/Views/Pages/CreateEntryView.swift. Do them one at a time and show me each diff.

1. The "Reference Photos" and "Characters" section labels overlay the content behind them and become unreadable. Add a background plate or shadow consistent with the app's existing style (check Extensions/Extensions.swift for existing modifiers before writing a new one).

2. The Entry Details (Next) page shows a "Current Storyboards" card even when there's only 1 storyboard. Hide the card below 2 storyboards, or relabel it "Current Storyboard" in the singular — your call, tell me which reads better in context.

3. The Add To Journal control at the top of the create page (with the carrot/chevron) doesn't save the selection when the entry hasn't been saved yet. Make it persist the draft first, then attach the journal. AddToJournalSheet is at ~line 10173.

4. Adding an unedited entry to a journal via the Save button in the Add To Journals sheet does nothing. Either make Save always commit the journal membership even with no text edits, or disable the button with a visible reason. Prefer the former.
```

### 5.4 — Deletion resilience

```
Storytopia/Services/Supabase/EntrySaveService.swift, deleteEntry() at ~line 1001, runs six sequential awaits (thumbnail, reference photos, characters, storyboards, memberships, entry row). If any one throws, the rest never run and the account is left with orphaned storage objects and rows.

Rewrite it so every sub-deletion is attempted regardless of earlier failures, collecting errors and throwing an aggregate at the end. The entry row deletion should still be last. Keep the existing 404-tolerance pattern from deleteStoryboards (~line 434), which correctly treats already-missing storage objects as success.
```

### 5.5 — Split the giant view files

```
Storytopia/Views/Pages/JournalView.swift is 766KB and CreateEntryView.swift is 487KB. Both are too large to work in.

Do JournalView.swift first, mechanically and with no behavior changes:
1. List every top-level type in the file with its line range, and propose a grouping into 5-8 files under Views/Pages/Journal/.
2. Show me that plan before moving anything.
3. Then move types one group at a time, keeping private access levels intact (types marked `private struct` at file scope will need `fileprivate` or internal — flag every one of those before changing it, since it's the main way this refactor breaks things).

Build and confirm no behavior change after each group.
```

---

## Phase 6 — Art and content

### 6.1 — Make art styles a real type

```
Art styles are currently a bare array of strings: Storytopia/Views/Pages/CreateEntryView.swift line 1696, `let artStyles = ["Anime", "Graphic Novel", "Pixel Art", "Manga", "Pop Art"]`, with defaultArtStyle at line 1695. The string is passed through to the generation prompt and stored as art_style in Supabase.

Refactor to an ArtStyle enum in Storytopia/Models/StoryModels.swift with, per case: rawValue (must equal the existing string exactly, so stored rows keep working), displayName, thumbnailAssetName, inlineThumbnailAssetName, and promptFragment — the text appended to the generation prompt.

Requirements:
- Existing art_style values in Supabase must continue to resolve. Anything unrecognized falls back to Anime, matching current behavior (see StoryModels.swift line 1007 and EntrySaveService.swift line 611).
- Asset names must match what's in Assets.xcassets/Art Style/ (art_style_anime, inline_art_style_anime, etc.).
- Update the picker at CreateEntryView.swift ~line 9139 and SharedViews.swift line 80 to drive off the enum.
- Do not change any generated prompt text in this step — extract only. I want to tune the fragments separately once I can see them in one place.
```

### 6.2 — Tune and add anime styles

```
Now that ArtStyle has promptFragment (see 6.1), I want to improve the anime output and add a new style.

1. Show me the current full prompt that gets sent for the Anime style — the assembled string, with the fragment, art style, character descriptions, and reference photo handling all in place. Find it in OpenAIImageGenerationService.swift and the prompt-building code in CreateEntryView.swift.
2. Rewrite the Anime fragment to be more specific about line weight, color palette, shading, and panel composition. Vague style words produce generic output; concrete art-direction terms don't.
3. Add a "Lo-fi Anime" case: muted desaturated palette, soft grain, warm lighting, quiet everyday composition.

For each change show me the before/after prompt text. I'll generate test images and iterate — don't guess at what looks good, just make the fragments easy for me to edit.
```

### 6.3 — Clothing / appearance notes on characters

```
Character appearance is currently taken entirely from the reference photo, so users can't change what a character wears.

Add an optional free-text "Appearance notes" field to characters:
1. New migration adding appearance_notes text to entry_characters (nullable). Existing rows must be unaffected.
2. Thread it through Storytopia/Services/Supabase/SupabaseReferencePhotoService.swift (character load/save) and the EntryCharacter model in StoryModels.swift ~line 308.
3. Add the field to CharacterEditorSheet in CreateEntryView.swift ~line 12034 — a multiline text field with placeholder "e.g. wearing a red raincoat and yellow boots", with a character limit.
4. Append it to the generation prompt for that character, phrased so it overrides the reference photo's clothing while preserving facial likeness.

Step 4 is the part that matters — show me the resulting prompt text.
```

### 6.4 — Move character likeness to entry level

```
The per-character likeness control didn't work well. Move it to the Entry Details page as a single setting that applies to all characters in the entry.

1. Find the existing likeness control in CreateEntryView.swift and the per-character likeness value on EntryCharacter (StoryModels.swift ~line 308).
2. Replace with one entry-level likeness value on the draft (CreateEntryDraft, StoryModels.swift ~line 428) plus a Supabase column on entries.
3. Surface it on the Entry Details (Next) page.
4. Existing per-character values: migrate to the entry-level value by taking the max, then drop the old column in a later migration — not the same one.
```

---

## Phase 7 — Later

### 7.1 — Comic reader views

```
Add a comic reader mode for storyboards, with horizontal (page-turn) and vertical (continuous scroll) options.

Surfaces that need it:
- "The Story So Far" page — vertical scroll
- Journal > Tap To Open — comic reader with a vertical scroll option
- Profile > Tap To Open — horizontal scroll

Build ONE reusable reader view (new file Storytopia/Views/Components/ComicReaderView.swift) that takes an ordered array of storyboards, a starting index, and an axis, rather than three separate implementations. It needs: pinch-to-zoom per page, a page indicator, and a reading-direction preference persisted in @AppStorage.

Show me the component with a preview first, then we'll wire it into each surface one at a time.
```

### 7.2 — Recent storyboard on homepage

```
Add the user's most recent completed storyboard to the top of the home page as a large card that opens the entry.

Storytopia/Views/Pages/HomeView.swift is the view. SupabaseStoryboardService.loadPrimaryCompletedStoryboards() in EntrySaveService.swift (~line 493) already fetches primary completed storyboards ordered by created_at desc — use it rather than writing a new query.

Signed out or with no storyboards, fall back to the existing home content — HomeView.swift line 67 shows the sample-content pattern.
```

---

## Things you asked that are already answered

**"Does deleting an entry delete the stored Storyboard image from the DB?"**
Yes. `EntrySaveService.deleteEntry()` (line 1001) calls `deleteStoryboards(clientEntryID:)` (line 463), which removes the storage objects (line 434) and the `entry_storyboards` rows. The gap is failure handling, not missing logic — see prompt 5.4.

**"Does Generate Storyboard save the entry if I never pressed Save?"**
Yes. `startStoryboardGeneration()` calls `makeEntryDraftSavePayload(forceSave: true)` at `CreateEntryView.swift:2577` before it does anything else. Still worth testing end-to-end that the cloud write completes, not just the local draft.

**"Where are the art styles in the code?"**
`CreateEntryView.swift:1696`. Prompt 6.1 turns them into something you can actually work with.

**"What happens when I de-select an entry from its own journal?"**
Not a bug report — a product decision. Recommend: the entry becomes journal-less and remains in Entries. Anything that deletes user writing as a side effect of a de-select is worse.
