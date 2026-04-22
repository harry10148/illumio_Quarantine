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

@test "exit 2 on partial failure (PUT returns 403)" {
    export MOCK_CURL_PUT_HTTP="403"
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --json
    [[ "$status" -eq 2 ]]
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
