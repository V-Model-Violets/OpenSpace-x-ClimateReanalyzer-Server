#!/usr/bin/env bash
# pull-sparse.sh — Lightweight deployment updater.
#
# Pulls the latest changes from the remote repository using a fast-forward-only
# merge (guaranteeing no unintended merge commits) and re-applies execute
# permissions on the project's shell scripts.
#
# Intended to be run on the server whenever a new version needs to be deployed.
# Safe to call repeatedly; will only move HEAD forward, never create divergence.

set -euo pipefail

# Absolute path to the live deployment directory on the server
DEST="/home/capstone/"

# The branch that represents the production-ready code
BRANCH="main"

cd "$DEST"

git sparse-checkout init --cone
git sparse-checkout set setup-ahtse.sh genconf.sh pull-sparse.sh zmap_tiler_v1.sh setup-ahtse_v2.sh

# Ensure we're on the right branch and clean
git checkout "$BRANCH" >/dev/null 2>&1 || true

# Ignore file permissions
git config core.fileMode false

# Only fast-forward (won't merge, won't create conflicts)
git pull --ff-only

# Re-apply execute permissions in case they were lost during checkout or transfer
chmod +x setup-ahtse.sh
chmod +x genconf.sh
chmod +x pull-sparse.sh
chmod +x zmap_tiler_v1.sh
chmod +x setup-ahtse_v2.sh