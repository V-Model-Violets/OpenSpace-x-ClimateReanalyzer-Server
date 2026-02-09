#!/usr/bin/env bash
set -euo pipefail

DEST="/home/capstone/"
BRANCH="main"

cd "$DEST"

# Ensure we're on the right branch and clean
git checkout "$BRANCH" >/dev/null 2>&1 || true

# Only fast-forward (won't merge, won't create conflicts)
git pull --ff-only

chmod +x setup-ahtse.sh
chmod +x genconf.sh
chmod +x pull-sparse.sh