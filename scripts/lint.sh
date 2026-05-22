#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift format lint --configuration .swift-format --recursive --parallel --strict Package.swift src
