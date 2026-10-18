# OpenShorts selection integration — 2026-10-16

Implemented native transcript windows, balanced model scoring across the selected
region, a diverse detail shortlist, nearby phrase cuts, and score-ordered overlap
suppression. Source and MIT notice are recorded in THIRD-PARTY-NOTICES.md and
included in the app bundle.

Passed:
- Debug Swift build and final release package build.
- `zsh scripts/transcript-selection-test.sh`: synthetic full-region/tail coverage,
  region bounds, balanced batching, failed/malformed model output, overlap rules,
  and phrase boundaries. Model scoring is injected in these tests.
- Import, persistence, invalid edit/destination protection, timed captions,
  combined overlay/subtitle rendering, and 1080×1920 MP4 export. These were run
  using a temporary copy of Tests/Smoke.swift with the three automatic-selection
  lines removed, isolating export from Vision. The runner's printed label still
  mentions selection bounds; that portion was NOT exercised in this isolated run.
- Ad-hoc app signature verification after clearing bundle extended attributes
  and re-signing the final bundle.

Not passed / not verified:
- Full smoke run stalled in the unchanged Vision OCR/Neural Engine compilation
  path before moment selection; stopped after more than two minutes.
- Editor model test failed twice at Tests/EditorModel.swift:87: preview timed out.
  One intermediate retry was invalidated by a concurrent source edit; the final
  retry used stable sources and reproduced the preview timeout.
- No real-footage before/after quality comparison or live Qwen scoring evaluation.
  Synthetic tests validate selection mechanics, not narrative quality.

The native renderer and subject tracker were not changed in this integration.
Long recordings may take longer because model scoring visits all transcript
windows. Whisper, karaoke highlighting, and speaker diarization remain deferred.
