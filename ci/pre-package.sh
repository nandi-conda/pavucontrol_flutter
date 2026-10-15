#!/usr/bin/env bash
# Run by the shared CI workflow before packaging: nimkit comes from the webby submodule.
set -euo pipefail
git submodule update --init --depth 1 vendor/webby
