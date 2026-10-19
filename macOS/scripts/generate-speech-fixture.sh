#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
fixture_dir=${1:-test-output/speech-workflow}
mkdir -p "$fixture_dir"
if [[ ! -f "$fixture_dir/narration.txt" ]]; then
  cp Tests/Fixtures/speech-narration.txt "$fixture_dir/narration.txt"
fi
if [[ -f "$fixture_dir/source.mp4" ]]; then
  print -u2 "Fixture already exists: $fixture_dir/source.mp4. Choose a new output directory to preserve it."
  exit 1
fi
say -r 165 -o "$fixture_dir/narration.aiff" -f "$fixture_dir/narration.txt"
runner_dir=$(mktemp -d /tmp/relio-speech-fixture.XXXXXX)
trap 'rm -rf "$runner_dir"' EXIT
swiftc -parse-as-library Tests/SpeechFixture.swift -o "$runner_dir/generate"
"$runner_dir/generate" "$fixture_dir/narration.aiff" test-output/pictures.mov "$fixture_dir/source.mp4"
