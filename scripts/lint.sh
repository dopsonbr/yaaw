#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Whole-tree formatting/style lint (swift-format owns force-unwrap/try/cast,
# trailing_comma, opening_brace, line_length per the deliberate split).
swift format lint --configuration .swift-format --recursive --parallel --strict Package.swift src

# Public-API documentation is enforced only on the library + protocol targets
# (master plan: AllPublicDeclarationsHaveDocumentation for YAAWKit/YAAWRenderProtocol).
if [[ -d src/Kit || -d src/RenderProtocol ]]; then
  swift format lint --configuration .swift-format-public --recursive --parallel --strict \
    src/Kit src/RenderProtocol
fi

# swiftlint enforces the tightened size/complexity thresholds.
swiftlint lint --config .swiftlint.yml src
