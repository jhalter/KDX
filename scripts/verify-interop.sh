#!/bin/bash
# Run the three live-network gates against explicitly selected peers, without launching either app.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${KDX_TEST_SERVER_HOST:-}" || -z "${KDX_TEST_TRACKER_HOST:-}" ]]; then
    cat >&2 <<'USAGE'
Set KDX_TEST_SERVER_HOST and KDX_TEST_TRACKER_HOST to the independent KDX
peers you want to test. This command opens network connections to both.
Optional ports: KDX_TEST_SERVER_PORT (10700), KDX_TEST_TRACKER_PORT (10800).
Set KDX_TEST_TABLE to an original challenge table or KDX_TEST_ARCHIVE to its
original archive, or import a table through either app first.
Account credentials, if needed, use KDX_TEST_SERVER_LOGIN and
KDX_TEST_SERVER_PASSWORD. Keep passwords out of command history and files.
These gates verify TCP connectivity, server login, and tracker queries.
They do not establish full file-transfer or UI interoperability.
USAGE
    exit 2
fi

export KDX_TEST_TCP=1
exec scripts/test.sh --filter 'IntegrationTests.testLiveTCP|LiveInteropTests'
