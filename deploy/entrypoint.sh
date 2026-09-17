#!/bin/sh
set -e

STORAGE_ROOT="${STORAGE_ROOT:-/var/lib/drone-feed/storage}"

# Named volumes mount as root; drop to app after fixing ownership.
if [ "$(id -u)" -eq 0 ]; then
  mkdir -p "$STORAGE_ROOT"
  chown -R app:app "$STORAGE_ROOT"
  exec runuser -u app -- "$0" "$@"
fi

bin/drone_feed eval "DroneFeed.Release.migrate()"
exec bin/drone_feed start
