#!/usr/bin/env bash
# Seed local dev database (admin@localhost / admin).
# Already runs as part of `mix ecto.setup` / `mix setup`; use this anytime afterward.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/apps/web"

export PGPORT="${PGPORT:-5434}"

echo "Seeding DroneFeed (PGPORT=${PGPORT})…"
mix run priv/repo/seeds.exs
