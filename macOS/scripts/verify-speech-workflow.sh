#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
if (( $# < 1 )); then
  print -u2 'Usage: zsh scripts/verify-speech-workflow.sh SYNTHETIC_PROJECT [ARTIFACT_DIRECTORY]'
  exit 1
fi
runner_dir=$(mktemp -d /tmp/relio-verify-speech.XXXXXX)
trap 'rm -rf "$runner_dir"' EXIT
swiftc Sources/RelioApp/Core.swift Tests/VerifySpeechWorkflow.swift \
  -Xcc -fmodule-map-file=Sources/CSQLite/module.modulemap -lsqlite3 -o "$runner_dir/verify"
"$runner_dir/verify" "$1" "${2:-test-output/speech-workflow}"
