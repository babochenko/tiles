#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift test --package-path "$ROOT" --filter TilesCoreTests
