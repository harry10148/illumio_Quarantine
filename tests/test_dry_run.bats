#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

@test "dry-run issues no PUT" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    assert_success
    run grep -c '^PUT' "$MOCK_CURL_LOG"
    assert_output "0"
}

@test "non-dry-run issues PUT for each match" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --json
    assert_success
    run grep -c '^PUT' "$MOCK_CURL_LOG"
    assert_output "1"
}
