# Handoff: finish the native Windows and Linux versions of Prism

You are taking over a half-finished port. Read this whole file before changing anything. The person you work for prefers short, direct answers; do not commit, push or install anything large (Docker images, Homebrew, system packages) without asking. The Mac has only about 15 GB free.

## Goal

Prism is a macOS app (Swift/SwiftUI, in `macOS/`) that turns one long video into vertical Shorts using Google Gemini: it transcribes, picks the strongest self-contained moments, cuts them on clean sentence and audio boundaries, frames the speaker in 9:16, adds styled captions and exports MP4s.

The person chose:

- **Native per platform:** a WPF app for Windows (`Windows/Prism.Windows`) and a GTK4 app for Linux (`Linux/Prism.Linux`, C# via Gir.Core). Both share one C# engine and app model in `Shared/Prism.Core`, so behavior can't drift between the two.
- **Every macOS feature at once,** including the chat assistant, timeline focus-point editing, Home folders and project stats.
- **The local .NET SDK** as the toolchain (already installed, see below).

The macOS app is the specification. When unsure how something should behave, read the Swift code and copy its behavior and wording.

## Rules that come from the person

- **Gemini is the only AI.** On-device AI was deleted on 2026-10-19; never add local models, Vision or speech frameworks.
- **Progress, errors and results appear as centered rounded cards over a dimmed background that blocks clicks;** only the card's buttons work. The macOS `generationOverlay`, `generationErrorOverlay`, `exportChoiceOverlay` and `exportDoneOverlay` in `macOS/Sources/RelioApp/EditorWorkspace.swift` show the pattern.
- **Without a saved Gemini key, a blocking "Welcome to Prism" card covers the whole app** until a key is pasted and checked with Google. See `apiKeyGate` in `RelioApp.swift`.
- **Don't change the macOS app** except to fix a bug you are sure of. It has many uncommitted fixes from 2026-10-19; don't revert them. Its internal names stay "Relio" (bundle ID, `~/Library/Application Support/Relio`, Keychain service `Relio.Gemini`).
- **The .NET apps must never read or write the macOS library.** They use `AppPaths`: `%LOCALAPPDATA%\Prism` on Windows, `~/.local/share/prism` on Linux.
- **Tests must never touch real data or the real key.** Redirect `AppPaths`, `Renderer.CacheDirectory` and `Gemini.RetryWaits`, and use fake key stores and the fake Gemini handler; `Shared/Prism.Core.Tests/Fixtures.cs` shows how.
- **Format everything sent to ffmpeg or Gemini culture-invariant.** This Mac uses a comma as its decimal separator.

## Repository

- `macOS/Sources/RelioApp/` is the reference:
  - `RelioApp.swift`: `AppModel` (all state and actions, lines ~28–1440) plus most screens (`ContentView`: sidebar, settings, Home dashboard, folders, project cards, create flow, key gate, stats sheet).
  - `EditorWorkspace.swift`: editor header, overlays, media bin, captions panel, player, inspector, timeline with focus track, keyboard shortcuts.
  - `GeminiSelection.swift`, `ShortMaker.swift`, `SubjectFraming.swift`, `TranscriptSelection.swift`, `Core.swift`: the engine.
  - `Theme.swift`: design tokens.
- `macOS/assets/readme/*.png` are screenshots of the macOS UI: home, create, editor, captions, layouts, brand. Use them as the visual reference.
- `macOS/packaging/Fonts/` holds the Prism fonts (Space Grotesk Medium, Sora, JetBrains Mono, with OFL licenses). The engine project links them into every app's output `Fonts/` folder.
- `Shared/Prism.Core/` (.NET 10 class library; packages Microsoft.Data.Sqlite, SkiaSharp 4.153.1, SkiaSharp.NativeAssets.Linux.NoDependencies):

  | File | Contents | State |
  |---|---|---|
  | `Models.cs` | Models, enums, titles and details for caption styles, video types, regions, export qualities | done |
  | `Storage.cs` | `PrismJson` (macOS-compatible JSON), `ProjectStore` (SQLite `state` table; `create: false` never creates files), `AppPaths`, `AppSettings` (replaces UserDefaults; JSON file in the config folder) | done |
  | `Errors.cs` | `ShortMakerException`, `GeminiException` (kinds and messages identical to macOS), `StageFailure` | done |
  | `Media.cs` | `FFmpeg`: locates ffmpeg/ffprobe via `PRISM_FFMPEG`/`PRISM_FFPROBE`, next to the app, or PATH; probe with rotation, frames, gray grids, audio chunks, audio levels | done |
  | `Gemini.cs` | `Generate<T>`: structured JSON output, retry waits `[2,4,8,15,30]` s, 429 RetryInfo, model fallback (`gemini-3.5-flash-lite` → `gemini-3.1-flash-lite` → `gemini-3.6-flash`, remembered 10 min), `OnRetry`/`OnFallback` | done |
  | `TranscriptSelection.cs`, `Selection.cs` | `GeminiSelection`: windows, five-criteria scoring, refine, final cut, video-type detection, parallel resumable transcription, word alignment, caption cues, chat `Interpret` | done |
  | `Framing.cs` | `SubjectFramer`: Gemini locate with frame times and timed speech, cut detection from 10 fps gray grids, `Plan`, `Eased` | done |
  | `ShortMaker.cs` | Full analysis pipeline, `PrepareShort`, `SilenceSnapped`, `StrongOpening`, `SpeechSafeRange`, split-screen speaker centers | done |
  | `Captions.cs` | `CaptionRenderer`: the macOS caption drawing ported to SkiaSharp, all seven styles plus highlight box and pop-in; `WriteTrack` writes transparent PNG frames plus an `ffconcat` list | done |
  | `Renderer.cs` | ffmpeg export and cached 540×960 previews. Layouts: Fill (cover crop with eased pan expression, hard cuts), Fit (blurred background), Split (vstack). Captions overlaid. Uses `-/filter_complex file` on ffmpeg ≥ 7, else `-filter_complex_script` | done |
  | `Platform.cs` | `IKeyStore`, `IPlatform` (trash, reveal, open folder, Downloads), `IPreviewPlayer`, `MachineProfile`, `ProjectInfo` (Home summaries, stats, Short counts), `Format` | done |
  | `Session.cs` | `AppSession` (INotifyPropertyChanged; the C# port of `AppModel`): all state, key handling incl. `VerifyAndSaveGeminiKey`, `FailureKind` | written, not compiled |
  | `Session.Projects.cs` | Create, open, recents, folders, rename, trash, import, `Inspect`, `UniqueDestination`, `ExportFileName`, `DisplayPath` | written, not compiled |
- `Shared/Prism.Core.Tests/`: xUnit, 28 tests, all passing, with real ffmpeg renders checked by pixel color and a fake Gemini (`FakeGemini`).
- `Windows/Prism.Windows/`: a WPF stub (`net10.0-windows`, `UseWPF`, `EnableWindowsTargeting`) with an empty window. It compiles on the Mac and can't run there.
- `Linux/Prism.Linux/`: a GTK4 stub (GirCore.Gtk-4.0 0.8.1, `RunWithSynchronizationContext`) with an empty window. It compiles; GTK isn't installed on the Mac, so it can't run there.

## Toolchain on this Mac

```sh
export PATH="$HOME/.dotnet:$PATH" DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1   # .NET SDK 10.0.402, user-local
export PRISM_FFMPEG=<path>/ffmpeg PRISM_FFPROBE=<path>/ffprobe
dotnet build Shared/Prism.Core && dotnet build Linux/Prism.Linux && dotnet build Windows/Prism.Windows
dotnet test Shared/Prism.Core.Tests
```

ffmpeg 9.0.2 for arm64 was unpacked in a temporary session folder (`/private/tmp/claude-501/.../scratchpad/ffmpeg-bin/`), which may be gone. If it is, re-download it into a new empty folder and check the SHA-256 before use:

- `https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffmpeg.zip`, sha256 `c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924`
- `https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/ffprobe.zip`, sha256 `fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6`

That build includes libass, fontconfig, libx264, libx265 and every filter the renderer uses. Docker exists but its daemon is off; don't start it without asking.

## Where it stopped

`dotnet build Shared/Prism.Core` fails with one error, because the next file was never written:

```
Shared/Prism.Core/Session.Projects.cs(96,13): error CS0103: The name 'SelectPreview' does not exist in the current context
```

## Remaining work, in order

### 1. Finish `AppSession`

Port the rest of `AppModel` from `macOS/Sources/RelioApp/RelioApp.swift` into two new partial files.

**`Session.Shorts.cs`:**
- `SelectPreview(Guid?)`:
  - Source video: `PreviewPath` = the video file.
  - A Short: `IsPreviewLoading`, then `Renderer.Preview(...)`; cancel the previous render and ignore stale revisions.
  - Gemini subject tracking runs only when `!IsBusy`, the Short's tracking version is stale, and a key exists; then save and re-preview.
  - With no video, clear `PreviewPath`/`PreviewSegment`.
- `MakeShorts`, `MakeConfiguredShorts`, `MakeShort`, `ContinueImport`, `CancelGeneration`:
  - Progress, `onTranscript` and Gemini callbacks hop to the UI thread with `Post`.
  - A cancellation token replaces Swift's `Task`.
  - Podcast type sets `SplitScreen` and middle captions, then finds speaker centers.
  - `AppendGeneratedShorts` (atomic, rolls back on save failure).
  - The final message goes through `WithModelNote`.
  - Failures set `GenerationError` with `FailureKind`.
- Export:
  - `ChooseExport(Guid? only)` and `DefaultExportFolder()` (Downloads › Prism › sanitized project title).
  - `Export(ExportChoice)`: if the folder can't be created, keep the card open with `Error`. Render ticked Shorts in project order, named after their titles, falling back to "<project> Short N". Copy the main videos as they are. Set `LastExport*`, `ExportedFiles`, `ExportSummary`.
  - `ExportAll` (for chat), `RevealExports`.

**`Session.Edits.cs`:**
- `ApplyEdit(Guid? to, bool captionsOnly, Func<EditSegment, MediaItem, string?>)`. Swift structs were copies, C# classes are not, so:
  - **Deep-clone the Short** (`PrismJson.Clone`) and write it back only on success.
  - **Undo snapshots are deep clones** of the segment list.
  - **An edit to a Short that isn't open must not switch the preview.**
- `Rebase` must keep the neighboring `preserveWholeFrame` flag on new end points.
- Port the remaining actions: `SetFraming`, `SetSplitScreen` (result saved to the Short it was made for, by ID), `HoldFramingAtCenter`, `RegenerateSelectedSubtitles` (saved by ID; refresh the preview only if that Short is open), `UndoFromEditor`, `RemoveShort`, `ToggleSelectedAudio`, `SetSelectedCaptionStyle`, `SetSelectedCaptionLayout`, `UpdateSelectedCaptionTexts`, `UpdateSelectedEdit`.
- `AdjustCropKeyframe`: stored position = clicked − (cropPosition − 0.5); starting points at 0.5; keep `IsSceneCut`/`PreserveWholeFrame` on every point.
- `RetrackSelectedSubject`.
- `AddManualClip` reads `Player?.CurrentTime` when the source is shown.
- Chat: `SendChat`, `ExecuteAICommand`, `HandleFallback`.
  - TRIM/START go through `Rebase`.
  - Search the original text case-insensitively, never with indices from a lowercased copy.
  - Append the model note as an extra assistant message.

**Then** port `macOS/Tests/EditorModel.swift` to xUnit using a fake `IPlatform` with an in-memory `IKeyStore`. Cover:
- the key card: `VerifyAndSaveGeminiKey` rejects on 400/401/403 and saves on other errors
- failure kinds
- custom range validation
- generated batches append without duplicates
- deep-cloned undo
- caption edits keep timing
- focus-point offset and scene cuts
- the export folder error stays on the card
- `Open` resets the last export folder
- every export path

Build and tests must pass.

### 2. Linux app (GTK4, Gir.Core)

Rebuild every macOS screen: the key card, sidebar (Home, Create Shorts, Editor, Settings, RAM and storage with refresh interval), Home, the five-step create flow, overlays, editor and Settings.

**Home:**
- Start card.
- Project grid: poster from `ProjectInfo.Summary`, title, Short count, date, duration badge.
- Show all / fewer, and an unfinished section.
- Folders with drag and drop and context menus: rename, move to folder, remove from folder, stats, trash.

**Create flow:**
- Upload by drag and drop, file dialog or typed path.
- Count, length and region with custom minutes.
- Caption style cards with `CaptionRenderer.StylePreview` images.
- Content-type cards.

**Editor:**
- Header with Exports, undo and Export.
- Media bin with Shorts/Captions tabs and thumbnails.
- Captions panel.
- Player: `Gtk.Video` showing `PreviewPath`; implement `IPreviewPlayer`.
- Inspector: Edit Short and the AI assistant.
- Timeline: a `Gtk.DrawingArea` with Cairo for the ruler, filmstrip, clip blocks, focus path (click to add, drag to move), text track, audio track, playhead and seeking.
- Shortcuts: Space, arrow keys (Shift for 5 s), Delete, Ctrl+Z. Ignore them while typing or while a card is open.
- Resizable panes.

**Settings:** show, edit, remove and test the key; model picker; resources.

**Look and platform:**
- Dark and light themes from the `Theme.swift` tokens through a `Gtk.CssProvider`.
- Fonts registered with fontconfig (`FcConfigAppFontAddDir`).
- `IPlatform`:
  - trash with `gio trash` (fall back to the freedesktop Trash spec)
  - reveal with the DBus `org.freedesktop.FileManager1.ShowItems`, falling back to `xdg-open` on the folder
  - key store via `secret-tool` (libsecret), falling back to a 0600 file in `~/.config/prism`
  - Downloads via `xdg-user-dir DOWNLOAD`

### 3. Windows app (WPF, code-only)

- The same screens and behavior, without `.xaml` markup compilation; `XamlReader.Parse` for styles is fine.
- `MediaElement` (manual LoadedBehavior) as the player, implementing `IPreviewPlayer`.
- Timeline drawn with `OnRender`/`DrawingContext`.
- Platform:
  - key file protected with DPAPI (`System.Security.Cryptography.ProtectedData` package) in `%APPDATA%\Prism`
  - Recycle Bin via `Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(..., RecycleOption.SendToRecycleBin)`
  - reveal with `explorer.exe /select,"path"`
  - Downloads via `SHGetKnownFolderPath(FOLDERID_Downloads)`
  - `OpenFolderDialog` for folders
- ffmpeg.exe/ffprobe.exe are expected next to `Prism.exe` or on PATH; `FFmpegMissingException` explains this.
- It must compile on the Mac via `EnableWindowsTargeting`.

### 4. Docs and housekeeping

- `Windows/README.md` and `Linux/README.md`: how to build and run, and what to install.
  - Linux: `ffmpeg`, `libgtk-4-1`, the GStreamer plugins Gtk.Video needs for MP4 (gst-plugins-good, gst-libav), `libsecret-tools`.
  - Windows: an ffmpeg build with libx264, libx265 and libass.
- A short section in the root `README.md`.
- `bin/` and `obj/` in `.gitignore`.
- A solution file.

### 5. Report back

Tell the person, in a few lines, what works, what was verified (builds, tests), and what could not run here. The Windows app never runs on the Mac, and the Linux app doesn't either without GTK. List the steps to check each on a real Windows PC and Linux machine.

## Look and wording

**Colors** (dark / light):
- ink `#0E0F14`; paper `#F6F3EC`
- surface0 `#0E0F14` / `#F6F3EC`; surface1 `#171920` / `#FFFFFF`; surface2 `#20232B` / `#EDE9E0`
- border `#2C2F37` / `#E2DED4`
- text `#F6F3EC` / `#0E0F14`; secondary `#8A8F98` / `#5C6068`
- action `#3FA9F5`; accent `#3FA9F5` / `#0B6CB5`
- coral `#FF6B57`; amber `#FFC233` / `#8F5E00`

**Type:** Space Grotesk Medium for display text, Sora for UI, JetBrains Mono for numbers and paths. Weights 400 and 500 only, sentence case, no gradients.

**Wording:** copy all user-facing text from the Swift code, including popup titles per failure kind ("No Shorts found", "Check your Gemini settings", "Gemini is unavailable right now", "Couldn’t make Shorts") and their buttons. Say "Recycle Bin" on Windows and "Trash" on Linux.

## Known engine limits (fine to keep)

- A Short whose framing path is only partly marked whole-frame renders as a crop; only fully whole-frame paths render as Fit.
- The filler-word lists for trimming openings and edges are English only.
