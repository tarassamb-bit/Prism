#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
swiftc Sources/RelioApp/Core.swift Sources/RelioApp/ShortMaker.swift Sources/RelioApp/TranscriptSelection.swift Sources/RelioApp/GeminiSelection.swift Sources/RelioApp/SubjectFraming.swift Sources/RelioApp/LocalVision.swift Sources/RelioApp/LocalAI.swift Tests/Smoke.swift \
  -Xcc -fmodule-map-file=Sources/CSQLite/module.modulemap -lsqlite3 \
  -o /tmp/relio-smoke
/tmp/relio-smoke
