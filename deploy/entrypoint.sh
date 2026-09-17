#!/bin/sh
set -e
bin/drone_feed eval "DroneFeed.Release.migrate()"
exec bin/drone_feed start
