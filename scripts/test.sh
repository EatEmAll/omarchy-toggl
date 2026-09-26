#!/usr/bin/env bash
# Python unit tests, Model.js tests (deno) and manifest validation.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
python3 -m unittest discover -s tests -t .
TZ=UTC deno test --allow-read --quiet tests/model_test.js
omarchy plugin validate .
