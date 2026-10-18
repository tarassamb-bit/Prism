#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
if (( $# != 2 )); then
  echo 'Usage: zsh scripts/real-video-test.sh SOURCE_VIDEO NEW_OUTPUT_DIRECTORY' >&2
  exit 1
fi
binary=$(mktemp /tmp/relio-real-video.XXXXXX)
trap 'rm -f "$binary"' EXIT
swiftc Sources/RelioApp/Core.swift Sources/RelioApp/ShortMaker.swift Sources/RelioApp/TranscriptSelection.swift Sources/RelioApp/GeminiSelection.swift Sources/RelioApp/SubjectFraming.swift Sources/RelioApp/LocalVision.swift Sources/RelioApp/LocalAI.swift Tests/RealVideo.swift \
  -Xcc -fmodule-map-file=Sources/CSQLite/module.modulemap -lsqlite3 -o "$binary"
"$binary" "$1" "$2"
