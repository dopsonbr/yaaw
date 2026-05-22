#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift format format --configuration .swift-format --recursive --parallel --in-place Package.swift src
