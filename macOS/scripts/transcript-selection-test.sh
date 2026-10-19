#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
test_dir=$(mktemp -d /tmp/relio-transcript-test.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
swiftc Sources/RelioApp/Core.swift Sources/RelioApp/TranscriptSelection.swift Tests/TranscriptSelectionTests.swift \
  -Xcc -fmodule-map-file=Sources/CSQLite/module.modulemap -lsqlite3 -o "$test_dir/transcript-test"
"$test_dir/transcript-test"
