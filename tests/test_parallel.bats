#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

@test "parallel=1 remains serial (all N PUTs happen)" {
    run bash "$SCRIPT" --targets "10.0.0.0/24" --label-id 878 \
        --mode append --non-interactive --json --parallel 1
    assert_success
    run grep -c '^PUT' "$MOCK_CURL_LOG"
    assert_output "2"
}

@test "parallel=4 completes with correct counts and PUT count" {
    run bash "$SCRIPT" --targets "10.0.0.0/24" --label-id 878 \
        --mode append --non-interactive --json --parallel 4
    assert_success
    [[ "$(echo "$output" | jq '.counts.updated')" == "2" ]]
    run grep -c '^PUT' "$MOCK_CURL_LOG"
    assert_output "2"
}

@test "parallel with an injected failure marks partial" {
    export MOCK_CURL_PUT_HTTP="500"
    run --separate-stderr bash "$SCRIPT" --targets "10.0.0.0/24" --label-id 878 \
        --mode append --non-interactive --json --parallel 2
    [[ "$status" -eq 2 ]]
    [[ "$(echo "$output" | jq '.counts.failed')" == "2" ]]
}

@test "parallel actually overlaps (faster than serial)" {
    export MOCK_CURL_PUT_DELAY_MS=500

    start=$(date +%s%3N)
    bash "$SCRIPT" --targets "10.0.0.0/24" --label-id 878 \
        --mode append --non-interactive --json --parallel 1 >/dev/null
    serial_ms=$(( $(date +%s%3N) - start ))

    : > "$MOCK_CURL_LOG"
    start=$(date +%s%3N)
    bash "$SCRIPT" --targets "10.0.0.0/24" --label-id 878 \
        --mode append --non-interactive --json --parallel 4 >/dev/null
    par_ms=$(( $(date +%s%3N) - start ))

    [[ "$par_ms" -lt $(( serial_ms * 3 / 4 )) ]]
}
