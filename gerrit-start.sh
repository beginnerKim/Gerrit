#!/usr/bin/env sh
set -e

echo "Starting Gerrit..."
exec su-exec ${GERRIT_USER} ${GERRIT_DIR_VOLUME}/bin/gerrit.sh ${GERRIT_START_ACTION:-daemon}
