_load_libs() {
    load "${BATS_TEST_DIRNAME}/lib/bats-support/load.bash"
    load "${BATS_TEST_DIRNAME}/lib/bats-assert/load.bash"
}

common_setup() {
    export REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    export SCRIPT="${REPO_ROOT}/update_illumio_workload_labels.sh"
    export BATS_TMPDIR_LOCAL="${BATS_RUN_TMPDIR:-/tmp}/iq_bats_$$"
    mkdir -p "$BATS_TMPDIR_LOCAL"

    export MOCK_CURL_LOG="$BATS_TMPDIR_LOCAL/curl_calls.log"
    export MOCK_CURL_FIXTURE_DIR="${REPO_ROOT}/tests/fixtures"
    : > "$MOCK_CURL_LOG"
    export PATH="${REPO_ROOT}/tests/helpers/mocks:$PATH"

    # Isolate credentials auto-discovery: point HOME at an empty dir and cd
    # away from REPO_ROOT so ./config/quarantine.conf isn't auto-picked up.
    export HOME="$BATS_TMPDIR_LOCAL/fake_home"
    mkdir -p "$HOME"
    cd "$BATS_TMPDIR_LOCAL"

    export ILLUMIO_QUARANTINE_API_USER="test_user"
    export ILLUMIO_QUARANTINE_API_PASS="test_pass"
    export ILLUMIO_QUARANTINE_PCE_URL="https://pce.test.local:8443"
    export ILLUMIO_QUARANTINE_ORG_ID="1"
}

common_teardown() { rm -rf "$BATS_TMPDIR_LOCAL"; }
