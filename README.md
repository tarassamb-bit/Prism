# Prism

Prism (formerly Relio) is a macOS-first video editor prototype with optional Gemini cloud editing. The first milestone is one source video to one vertical MP4 Short. The current implementation is an **early Phase 1 slice**, not a completed AI editor.

## Run

Requires macOS 14 or newer and Xcode command line tools.

```sh
zsh scripts/package-app.sh
open dist/Prism.app
```

Prism opens on a home dashboard with recent projects and Settings in the main sidebar. **Create a video** asks for a video first, reads its actual duration, then presents Short count, length and source range: entire video, first half, last half or custom minutes. Out-of-duration settings block generation. Choose Gemini cloud AI and save a Google AI Studio key in Settings to use cloud clip selection, transcription and editor chat; the key is stored in macOS Keychain. Cloud analysis sends audio, transcripts and sampled frames to Google, and API charges may apply. Video rendering and subject tracking run on the Mac. Relio copies the selected source video into its managed library. Auto Shorts combines visual and audio cues and proposes distinct clip ranges; review each suggestion before export.

## Architecture

```
Sources/RelioApp/
  RelioApp.swift   SwiftUI shell, project actions, preview
  Core.swift       SQLite project store, media metadata, model interface
  ShortMaker.swift On-device speech/vision analysis, selection, AVFoundation render
Sources/CSQLite/   SQLite C module
```

The UI sends asynchronous tasks to the media pipeline, then receives a typed `ShortResult` and persists an `EditSegment`. Apple Vision and Speech run locally. Gemini cloud mode scores transcript windows, refines a shortlist for distinct story moments, and returns titles and reasons. Creating more Shorts excludes previously selected source intervals. The cloud path uses native Vision framing and does not start the downloaded local language model. Word captions are checked against the selected transcript and timing anchors; if alignment remains incomplete, Relio retains complete sentence captions and marks their timing approximate. The renderer consumes structured source ranges, never arbitrary model text. AVFoundation is used in this initial prototype because it ships with macOS.

## Project schema

The managed library lives at `~/Library/Application Support/Relio/Library`. Each `.relio` project contains `project.sqlite` in WAL mode plus `Media/`, `Thumbnails/`, and `Exports/`. Imported source files are copied into `Media/` and the originals are never modified. SQLite stores a versionable JSON project record with project ID, name, managed media paths, metadata, notes, priority, edit segments, project memory, and creation date. Global preferences live in the app support database.

An edit segment has an ID, source media ID, source start in seconds, duration, overlay text, optional timed subtitle phrases, framing mode, and audio mute state. Output format, crop keyframes, transitions, and an explicit schema version remain future schema work. Validation ensures source ranges fit before render.

## Smoke test

Run `zsh scripts/smoke-test.sh`. It builds a four-second video from three generated picture scenes, imports it, saves and reopens a SQLite project, exports a three-second vertical MP4 with a caption, and checks output dimensions, duration, and size. The output is saved in `test-output/picture-short.mp4`, with a decoded preview frame beside it. This exercises the media engine directly; it does not automate the SwiftUI button clicks or test speech recognition.

The desktop flow was also exercised manually with `test-output/pictures.mov`: import, create one Short, export `test-output/ui-short.mp4`, quit, and reopen. The saved plan survived restart. Finder metadata reports a four-second, 1080 × 1920 MP4. The source has no audio, so this test does not verify transcription or timed captions.

## Phase 1 boundary and risks

Phase 1 should deliver reliable large-video import, local transcription, meaningful moment selection, subject-aware crop, timed captions, preview of the actual result, and H.264 MP4 export. The current selection ranks sampled frame classifications, person/face detections, frame-to-frame motion, scene-label variety, and recognized speech, then proposes non-overlapping windows. It does not understand a video's narrative or guarantee viral moments. Auto-generated Shorts follow sampled person/face centers with a smoothed crop path; this does not identify a specific person across cuts or understand who is speaking. Fit preserves the whole frame. Captions use on-device speech timestamps when recognition is available. Active-speaker identity, word-level karaoke highlighting, long-source memory/performance, and recognition across all languages remain open areas.

Major risks: on-device speech support varies by language and OS; Vision labels and face/person detections are signals, not story comprehension or speaker identity; preview renders use the export pipeline and can take time; long recordings may need a proxy/indexing pipeline; and source paths may break if media is moved outside a managed project.

YouTube, analytics, AI Coach, licensing, mixed-media storytelling, speaker memory, and broad Creator Brain learning are deliberately deferred until the core Short pipeline is reliable.

## Release hardening

See [RELEASE-READINESS.md](RELEASE-READINESS.md) for verified behavior, release packaging, and remaining commercial launch gates. Packaging now defaults to an optimized release build.

## Desktop editing workspace

The editor uses a CapCut-inspired desktop layout with a left media bin, central player, right clip inspector, and bottom timeline. Add a clip manually or use Auto Shorts. Auto-generated Shorts use Vision person and face locations, then attention saliency for other visual subjects, to follow the main visual focus with a smoothed crop path; clips with no clear subject hold a steady crop. Older clips are tracked the first time they are selected or exported. The detailed tracking scan runs every half second in selected Shorts. Speech timestamps keep Auto Short and manual trim boundaries on complete words when on-device recognition is available, so the final duration can vary slightly from the requested target. Select a Short to adjust start, duration, text timing, Fit/Fill framing, tracking offset, and source audio. Older projects default to centered framing. Apply saves and re-renders the preview. Export writes every Short as its own MP4.

Run `zsh scripts/editor-model-test.sh` to validate editor actions directly, or provide a source-video path to test your footage. See [editor-qa.md](editor-qa.md) for the distinction between functional checks and the currently blocked computer-control checks.

## Open-source moment selection

The long-to-short selector adapts OpenShorts' MIT-licensed transcript windows,
balanced batches, and overlap suppression into native Swift. See
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for the pinned source and license.
The native integration needs no Python or Docker. Optional Gemini cloud editing uses your own Google AI Studio key. The installed
Qwen model is optional; unavailable or malformed scoring falls back to the
existing visual/speech ranking. Full-region scoring can add inference time on
long recordings. Each model excerpt is capped at 2,400 characters.

Cuts prefer nearby phrase endings, punctuation, or pauses before applying word
boundary protection. Captions are short speech groups, so these boundaries do
not guarantee complete sentences or self-contained stories. Final selection
rejects clips sharing 25% or more of the shorter clip, highest score first.

Run `zsh scripts/transcript-selection-test.sh` for synthetic transcript checks
covering full-region coverage, late moments, batching, model failures, boundaries,
and duplicate suppression. These checks do not measure real-world clip quality.
Whisper transcription, karaoke captions, and speaker diarization are not part
of this integration.

## Google AI Studio cloud editing

Open **Settings** in the main sidebar, enable **Use cloud AI**,
paste your API key, and choose **Save key**. The key is stored in macOS Keychain,
not the project or preferences. **Test connection** checks access to the selected
model using a small API request. You can change the model or remove the saved key
in the same panel. Saving a key enables cloud mode.

In cloud mode, Gemini transcribes sentence-level audio in chunks up to two minutes, scores overlapping
transcript windows across the selected region, then refines a shortlist into
clips with strong openings, context and complete endings. Only the chosen clips
receive detailed word timing for captions and speech-safe cuts. The alignment is
checked against the selected sentence and timing anchors; if words are missing or
the timing drifts, complete sentence captions are retained with an approximate-
timing notice. **Create more Shorts** excludes already-selected source intervals.
This adapts OpenShorts'
score → shortlist → detail pipeline. Clips are bounded, ranked globally by score,
and deduplicated before local word-boundary protection and rendering. The default
source region is now the entire video. Silent footage uses sampled visual context.
Sparse frames do not give Gemini a full motion view of the recording.

Editor chat and subtitle regeneration also use Gemini while cloud mode is enabled.
Google receives audio chunks, transcripts, sampled frames (up to 12 per refinement batch), and (for chat) requests,
recent conversation and an edit summary. API usage can incur charges. Audio is
prepared in temporary files that are removed after each request; requests use an
ephemeral URL session. Source files are preserved. Subject tracking, preview and
MP4 rendering still run on the Mac. No downloaded local language model or Apple
Speech permission is needed for cloud mode. Turning cloud mode off restores the
local pipeline. Cloud errors are surfaced instead of silently switching to local AI.

Run `zsh scripts/gemini-selection-test.sh` for deterministic tests of window ranking,
late moments, missing/duplicate ids, clip bounds, transcript offsets, malformed
timestamps, credential transport, truncated responses and quota errors. These use
a mock API, not a paid live request; real clip quality and cloud timestamp accuracy
still require review on actual speech footage with your key.

## Upload and source ranges

The creation flow asks for a video first. After import, Relio reads and displays
its actual duration, then shows the Short count, length and source-range settings.
Choose Entire video, First half, Last half, or Custom range. Custom start/end
values are in minutes (decimals supported). Invalid, reversed or out-of-duration
ranges show an error and disable generation. The media pipeline checks the range
again against the actual file duration before any analysis or cloud request.

## Generation and review improvements

Home opens video upload directly. A new project is created when a video is
chosen, rather than when the upload screen is opened. After import, choose the
range and generate. The generation progress includes Cancel; cancellation stops
network requests and propagates to frame scanning and subject tracking. Existing
clips are only changed after a full successful analysis and database save.

New batches append distinct clips instead of replacing previous work. Overlapping
candidates are skipped, and a batch can be undone. Gemini suggestions carry a
short title and selection reason into the media bin and clip inspector; these are
review notes, not video overlays or measured quality guarantees. Fit layouts are
also reflected in the inspector. Older projects remain readable.

Small word-timestamp overlaps are normalized without dropping speech. Word-level
alignment uses short audio chunks, compares the transcript and timing anchors with
the selected sentence, and retries questionable responses in smaller chunks down
to five seconds. If words remain incomplete or drift from the reference, Relio
keeps the full sentence captions and labels their timing as approximate. Cloud
mode uses native Vision tracking without starting the downloaded local vision
language model. Temporary Google server errors retry at most twice; quota and key
errors remain actionable failures. Cloud calls and retries can incur API usage.
Deterministic tests exercise timing recovery, transient server recovery, duplicate
filtering, persistence, source bounds, and export; real-world narrative quality
still needs review with speech footage.

A synthetic spoken-video fixture can be created with
`zsh scripts/generate-speech-fixture.sh` after the smoke test has made
`test-output/pictures.mov`. Its two self-contained stories, intro and outro make
it possible to inspect whether selection preserves hooks and payoffs without
uploading private footage. Generate into a fresh directory to preserve previous
fixtures. Running this fixture through cloud mode uses the configured Google key
and incurs normal API usage.

After exporting the two synthetic Shorts, verify their speech, duration, picture,
audio and vertical output with `zsh scripts/verify-speech-workflow.sh PROJECT_DIRECTORY`.
The check also requires approximate-timing captions to carry their notice.

## Brand

The interface follows the Prism design system: Ink `#0E0F14` ground, Sky blue `#3FA9F5` as the only action color, Space Grotesk headlines, Sora interface text and JetBrains Mono timecodes (fonts in `packaging/Fonts`, SIL Open Font License). Tokens live in `Sources/RelioApp/Theme.swift`. Internal identifiers (bundle ID, the `Relio` Application Support folder, the `Relio.Gemini` Keychain item, source folder names) keep the old name so existing projects, settings and the saved key keep working.
