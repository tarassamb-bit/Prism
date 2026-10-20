# Prism for Linux

Native GTK4 interface (Gir.Core), sharing the Gemini engine and app model with Windows in `Shared/Prism.Core`. The library is separate from the macOS app.

## Requirements

- .NET 10 SDK to build, or .NET 10 runtime for a published framework-dependent app.
- GTK 4.12 or newer, its GStreamer media backend, Cairo and fontconfig.
- `ffmpeg` and `ffprobe`, with libx264, libx265 and libass support.
- GStreamer playback plugins: plugins-base, plugins-good and libav, for MP4 video and AAC audio in `Gtk.Video`.
- `secret-tool` (`libsecret-tools`) and a running desktop Secret Service/keyring are recommended for the Gemini key.
- `gio`, `gdbus`, `xdg-open` and `xdg-user-dir` for desktop integration.

For example, on Ubuntu 24.04 or newer, install the .NET 10 SDK and these desktop packages:

```sh
sudo apt install ffmpeg libgtk-4-1 libgtk-4-media-gstreamer fontconfig \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-libav \
  libsecret-tools libglib2.0-bin xdg-utils
```

Other distributions use names such as `gtk4`, `gst-plugins-good` and `gst-libav`. The bundled Sora, Space Grotesk and JetBrains Mono fonts are registered with fontconfig for this process; their OFL licenses ship alongside them.

## Build and run

From the repository root:

```sh
dotnet build Linux/Prism.Linux
dotnet run --project Linux/Prism.Linux
```

The first window is a blocking **Welcome to Prism** card. Create a Google AI Studio key, paste it, and choose **Save and continue**. Google rejects invalid keys; a temporary Google/network outage does not prevent saving a key. The Settings screen can show, replace, remove and test it.

Prism finds ffmpeg/ffprobe beside the application or on `PATH`. To use explicit paths:

```sh
export PRISM_FFMPEG=/path/to/ffmpeg
export PRISM_FFPROBE=/path/to/ffprobe
dotnet run --project Linux/Prism.Linux
```

Optional framework-dependent distribution (run this on the build machine; use `linux-arm64` for ARM):

```sh
dotnet publish Linux/Prism.Linux -c Release -r linux-x64 --self-contained false -o dist/linux-x64
./dist/linux-x64/Prism.Linux
```

Keep the full output folder, including native libraries, `Fonts/` and `Brand/`. GTK, GStreamer and ffmpeg remain system requirements.

## Files and desktop behavior

- Projects: `~/.local/share/prism/Library/Projects` (`XDG_DATA_HOME` is respected).
- Settings: `~/.config/prism/settings.json` (`XDG_CONFIG_HOME` is respected).
- Key: desktop Secret Service through `secret-tool`; if unavailable, `gemini.key` in the config directory with mode **0600** and a private directory.
- Exports default to the desktop Downloads location, under `Prism/<project title>`. The export card can change the folder, choose Shorts and include untouched source videos.
- Trash uses `gio trash`, with a freedesktop home Trash fallback. Reveal uses `org.freedesktop.FileManager1.ShowItems`, then falls back to opening the containing folder.

No .NET code reads or writes the macOS Relio library or Keychain.

## Check on a Linux desktop

1. Start with no saved Prism key. Confirm the welcome card blocks navigation, invalid keys are rejected, and a saved key survives a restart. Test show/hide, replace, remove and connection testing in Settings.
2. Import a video using the dialog, a dropped file and a typed path. Walk through count/length/range, captions and content type. Invalid custom minutes must block the next step. Generate Shorts and cancel a second batch; the first batch must remain.
3. Play and seek source/Short previews. Try Fill, Fit and Split, subtitle styles/text/layout, trim, mute, undo, a manual clip from the source playhead, and focus-point clicks/drags. Check Space, arrows, Shift+arrows, Delete and Ctrl+Z; typing and open cards must suppress editor shortcuts. Try editor chat.
4. Export a subset, then all Shorts plus the source, using each quality. Check 9:16 MP4 playback, captions, audio and filenames. Try an unusable folder: its error must stay on the export card. Cancel an export and check that finished files remain and temporary files disappear.
5. On Home, create/rename folders, drag projects between them, remove a project from a folder, rename it and inspect stats. Move a disposable project to Trash and restore it with the desktop file manager. Reopen another project and check Exports points to its folder. Check both themes, pane resizing and resource refresh settings.

If MP4 previews cannot play, check the GTK GStreamer backend and the plugins above. Rendering requires ffmpeg even when the player can open the source.

## Automated checks

With ffmpeg/ffprobe available:

```sh
dotnet test Shared/Prism.Core.Tests
```

The shared tests use throwaway data/config/cache directories, fake key stores and fake Gemini HTTP replies. They never use a real library or key. The GTK interface compiles on the development Mac, but playback, desktop services and visual layout require the Linux checks above.
