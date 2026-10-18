# Third-party notices

## OpenShorts

Relio's `TranscriptSelection.swift` and `GeminiSelection.swift` adapt transcript window construction, balanced
scoring batches, global ranking, and score-ordered overlap suppression from `clip_selection.py`,
and the score → shortlist → detail flow and editing criteria from `main.py` and
`gemini_worker.py` at the same pinned revision:
https://github.com/mutonby/openshorts/blob/29753898a054f1783af67f5917e7d560fa7ef5ad/clip_selection.py

Copyright (c) 2024 OpenShorts. Licensed under the MIT License; the complete notice
is in `licenses/OpenShorts-MIT.txt`. No code from OpenShorts' commercially licensed
`cloud/` directory is included. Relio uses native Swift, optional Gemini API requests, Vision tracking, and its
AVFoundation renderer; no OpenShorts runtime is required.
