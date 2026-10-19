# Relio clipping flow QA

Validated with the synthetic 65.94-second spoken video in `test-output/speech-workflow/source.mp4`. It contains two narrated how-to stories, an intro and credits.

| Check | Evidence |
| --- | --- |
| Upload-first flow and duration-bound source settings | Editor model coverage verifies upload waits for file selection, imported duration initializes the custom range, and invalid minute ranges disable generation. |
| Cloud setup and provider transport | The installed app exposes Settings in the main sidebar, saved-key status in macOS Keychain, cloud switch, model field and connection test. Mock tests cover key header transport, no key in URL, failure handling and transient retries. |
| Story selection and clip edits | A live Gemini run selected the electricity-bill and tomato-water stories while skipping intro/credits. A separate live “Create more Shorts” run preserved the existing electricity clip and selected only the unused tomato clip. |
| Captions and export | Caption smoke checks verify phrases replace one another and disappear after their interval. Two live exports were verified at 1080×1920 with audio and complete spoken hooks/payoffs. |
| Project persistence and undo | Editor model checks generated batches append and deduplicate, save/reopen, retain metadata and support undo. |
| Framing | Planner and rendered-video checks cover steady framing, fast movement, scene cuts and crop reset at each cut. |
| Regression suites | `scripts/gemini-selection-test.sh`, `scripts/transcript-selection-test.sh`, `scripts/editor-model-test.sh`, `scripts/framing-test.sh` and `scripts/smoke-test.sh` passed. The release build completed. |

A live “Create more” run revealed that Gemini can return valid-looking word times while omitting speech from the opening and payoff. The new safeguard checks the detailed transcript against the selected full sentence and its timing anchors. If alignment remains incomplete, Relio keeps the full sentence captions and labels their timing approximate. The final-build behavior is covered by mock cloud-engine and transcript tests. The desktop UI bridge stopped responding before a second live cloud run could verify this new fallback, so that specific path is not live-cloud-verified. The export verifier expects exactly the two synthetic stories; it passed on the original live project exports and was not applicable to the QA clone, which contains only one preserved clip and no exports.

The synthetic sample validates this speech and export scenario. It cannot establish that every source video contains a strong standalone story or that every crop will track a person correctly. Review clips before publishing.
