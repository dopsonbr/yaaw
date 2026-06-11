#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Whole-tree formatting/style lint (swift-format owns force-unwrap/try/cast,
# trailing_comma, opening_brace, line_length per the deliberate split).
swift format lint --configuration .swift-format --recursive --parallel --strict Package.swift src

# Public-API documentation is enforced on the library + protocol targets
# (master plan: AllPublicDeclarationsHaveDocumentation for YAAWKit/YAAWRenderProtocol).
# During the rewrite this pass is report-only (DECISIONS-LOG D-007); the cutover
# gate sets YAAW_LINT_DOCS=1 to make it blocking once the doc sweep is complete.
if [[ -d src/Kit || -d src/RenderProtocol ]]; then
  if [[ "${YAAW_LINT_DOCS:-0}" == "1" ]]; then
    swift format lint --configuration .swift-format-public --recursive --parallel --strict \
      src/Kit src/RenderProtocol
  else
    echo "note: public-API doc lint is report-only (set YAAW_LINT_DOCS=1 to enforce):"
    swift format lint --configuration .swift-format-public --recursive --parallel \
      src/Kit src/RenderProtocol 2>&1 | grep -c "Documentation" \
      | xargs -I{} echo "  {} undocumented public declaration(s) outstanding" || true
  fi
fi

# swiftlint enforces the tightened size/complexity thresholds.
swiftlint lint --config .swiftlint.yml src
