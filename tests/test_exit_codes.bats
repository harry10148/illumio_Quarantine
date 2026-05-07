#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

@test "exit 0 on success" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    assert_success
}

@test "exit 3 on no match" {
    run bash "$SCRIPT" --targets "192.0.2.99" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    [[ "$status" -eq 3 ]]
}

@test "exit 4 when every PUT fails with 401 (auth failure)" {
    export MOCK_CURL_PUT_HTTP="401"
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --json
    [[ "$status" -eq 4 ]]
}

@test "exit 4 when every PUT fails with 403 (auth failure)" {
    export MOCK_CURL_PUT_HTTP="403"
    # Ensure we match workloads and reach PUT phase
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --json
    # This test verifies the new override: all PUTs returned 403 → exit 4
    [[ "$status" -eq 4 ]]
}

@test "exit 4 on PCE auth failure" {
    export MOCK_CURL_AUTH_FAIL="1"
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    [[ "$status" -eq 4 ]]
}

@test "exit 4 on PCE unreachable (curl network failure)" {
    export MOCK_CURL_UNREACHABLE="1"
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    [[ "$status" -eq 4 ]]
}

@test "exit 5 on invalid --mode" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode bogus --non-interactive --dry-run --json
    [[ "$status" -eq 5 ]]
}

@test "--connect-timeout flag present in CURL_OPTS" {
    # Static check: the script must use --connect-timeout so unreachable PCEs fail fast.
    run grep -n 'connect-timeout' "$SCRIPT"
    assert_success
    assert_output --partial "CURL_OPTS"
}

@test "TLS verification is enabled by default (no global -k in CURL_OPTS)" {
    run grep -n 'CURL_OPTS="-s --connect-timeout 10 --max-time 30"' "$SCRIPT"
    assert_success
}

@test "exit 2 on partial failure (first PUT fails, rest succeed)" {
    # Reset the mock curl PUT count file for this test
    rm -f "${BATS_TMPDIR_LOCAL:-/tmp}/mock_curl_put_count"
    export MOCK_CURL_PUT_HTTP_FIRST_FAIL="1"
    run bash "$SCRIPT" --targets "10.0.0.5,10.0.0.6" --label-id 878 \
        --mode append --non-interactive --json
    # First PUT returns 403, second returns 204 → genuinely partial → exit 2
    [[ "$status" -eq 2 ]]
}
