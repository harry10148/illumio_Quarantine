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

@test "parallel starts PUTs closer together than serial" {
    export MOCK_CURL_PUT_DELAY_MS=500

    bash "$SCRIPT" --targets "10.0.0.0/24" --label-id 878 \
        --mode append --non-interactive --json --parallel 1 >/dev/null
    mapfile -t serial_ts < <(awk -F'\t' '$1=="PUT"{print $4}' "$MOCK_CURL_LOG")
    [[ "${#serial_ts[@]}" -eq 2 ]]
    serial_gap=$(( serial_ts[1] - serial_ts[0] ))
    [[ "$serial_gap" -lt 0 ]] && serial_gap=$(( -serial_gap ))

    : > "$MOCK_CURL_LOG"
    bash "$SCRIPT" --targets "10.0.0.0/24" --label-id 878 \
        --mode append --non-interactive --json --parallel 4 >/dev/null
    mapfile -t parallel_ts < <(awk -F'\t' '$1=="PUT"{print $4}' "$MOCK_CURL_LOG")
    [[ "${#parallel_ts[@]}" -eq 2 ]]
    parallel_gap=$(( parallel_ts[1] - parallel_ts[0] ))
    [[ "$parallel_gap" -lt 0 ]] && parallel_gap=$(( -parallel_gap ))

    [[ "$parallel_gap" -lt "$serial_gap" ]]
    [[ "$serial_gap" -ge 300 ]]
}
