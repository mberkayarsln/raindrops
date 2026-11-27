#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project Raindrops.xcodeproj -scheme Raindrops -configuration "${CONFIGURATION:-Release}" -derivedDataPath build -quiet build
echo "Built: $(pwd)/build/Build/Products/${CONFIGURATION:-Release}/Raindrops.app"
