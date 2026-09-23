#!/bin/bash
#
# Scripts/test.sh — runs the full Swift Testing suite in debug, then builds the
# test bundle against a release build of the app.
#
# The test target uses `@testable import MonospaceNotes`, which a release build
# only allows when the module is compiled with testing enabled; plain
# `swift build --build-tests -c release` therefore cannot resolve the module.
#
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

printf '==> swift test (debug)\n'
swift test

printf '\n==> swift build --build-tests -c release (testing enabled)\n'
swift build --build-tests -c release -Xswiftc -enable-testing

printf '\nAll test gates passed.\n'
