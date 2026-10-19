# Relio release readiness

The app is a local video-to-vertical-Short editor. It is not yet approved for a commercial production release.

## Verified engine behavior

Run `zsh scripts/smoke-test.sh` for generated-video import, SQLite project persistence, bounded Short selection, corrupt input rejection, invalid edit rejection, preservation of existing destinations, caption timing, and 1080 × 1920 MP4 export.

Short preview renders through the same exporter used for delivery. Rendering takes time before playback starts. Editing commands have a built-in fallback when the optional Qwen runtime is absent. Auto Shorts ranks sampled Vision frame classifications, person/face detections, frame-to-frame motion, scene-label variety, and on-device speech when available. Imported media is copied into the project; moved project folders resolve their managed assets locally.

## Build

`zsh scripts/package-app.sh` builds an optimized release app at `dist/Relio.app`. Default ad-hoc signing supports local testing only. Set `RELIO_SIGNING_IDENTITY` to your Developer ID Application identity to sign with hardened runtime. Notarization and stapling still need your Apple developer credentials and must be completed before distributing publicly. The script verifies the resulting signature.

## Remaining launch gates

- Real speech fixtures: verify permission denial, languages, timed subtitles, and long recordings. Current phrases are timed as small word groups; there is no word-level highlight.
- Bound speech recognition time and add cancellation for analysis and export. Visual frame scanning reports progress.
- Verify portrait, rotated, HDR, variable-frame-rate, and audio-containing sources on supported macOS versions; verify audio sync and muting.
- Manually exercise the full desktop workflow, including edits on different Shorts, undo, restart, moved projects, missing media, low disk space, and failures during save.
- Add active-speaker-aware framing if it is part of the promised product; current Fill crop glides side to side without tracking the speaker.
- Finish or remove placeholder creation modes and controls before marketing them.
- Complete Developer ID signing/notarization, release versioning, installer/update strategy, customer support, and product pricing/licensing decisions.

Generated silent-video tests do not establish speech accuracy or commercial readiness. No billing, license server, or customer-facing service was deployed in this change.

## Real-video test — October 4, 2026

Tested `~/Downloads/video-1790957260292.mp4`: 1280 × 720, 798.58 seconds, with audio. Managed import, project save/reopen, three fallback 30-second selections, 1080 × 1920 exports, and frame decoding passed. Also rendered a full-frame alternative after visual inspection showed the centered crop removed useful CAD interface content. The editor now offers **Fit entire video** and **Fill vertical frame** in the preview menu.

Outputs are in `test-output/downloads-video-test-20261004-fit/`. Desktop automation could not initialize. Speech recognition could not run in the command-line harness because macOS attributed the privacy request to the terminal host without a speech usage description. No speech permissions were changed. These tests explicitly disable transcription and validate fallback selection; they do not validate moment quality, subtitles, or desktop interaction.

(`scripts/real-video-test.sh` was removed on October 19, 2026, with the on-device pipeline it exercised.)

## Real-video regression — October 11, 2026

After adding motion scoring to Auto Shorts, reran the same 1280 × 720, 798.58-second source. The selector returned three distinct 30-second moments at 71.3, 543.8, and 686.3 seconds. All three exports passed 1080 × 1920 dimension, duration, audio-track, and decoded-frame checks; the Fit alternative rendered. Speech recognition remained disabled in this command-line run, so subtitle accuracy was not evaluated. Outputs are in `/tmp/relio-motion-analysis-qa-20261011/`.
