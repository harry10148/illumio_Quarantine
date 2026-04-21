#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

@test "single IP target uses ?ip_address= (server_side)" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --non-interactive --dry-run --json
    assert_success
    [[ "$(echo "$output" | jq -r '.search_strategy')" == "server_side" ]]
    run grep -c "workloads?ip_address=10.0.0.5" "$MOCK_CURL_LOG"
    refute_output "0"
    run grep -c "workloads[^?]*$" "$MOCK_CURL_LOG"
    assert_output "0"
}

@test "hostname target uses ?hostname= (server_side)" {
    run bash "$SCRIPT" --targets "server1.lab.local" --label-id 878 \
        --non-interactive --dry-run --json
    assert_success
    [[ "$(echo "$output" | jq -r '.search_strategy')" == "server_side" ]]
    run grep -c "workloads?hostname=server1.lab.local" "$MOCK_CURL_LOG"
    refute_output "0"
}

@test "CIDR target forces full_scan" {
    run bash "$SCRIPT" --targets "10.0.0.0/24" --label-id 878 \
        --non-interactive --dry-run --json
    assert_success
    [[ "$(echo "$output" | jq -r '.search_strategy')" == "full_scan" ]]
}

@test "mixed targets (ip + cidr) fall back to full_scan" {
    run bash "$SCRIPT" --targets "10.0.0.5,10.0.0.0/24" --label-id 878 \
        --non-interactive --dry-run --json
    assert_success
    [[ "$(echo "$output" | jq -r '.search_strategy')" == "full_scan" ]]
}

@test "server-side result excludes unmanaged workloads" {
    # 10.0.0.7 belongs to unmanaged workload; mock server returns it, filter drops it
    run bash "$SCRIPT" --targets "10.0.0.7" --label-id 878 \
        --non-interactive --dry-run --json
    # exit 3 no_match because unmanaged was filtered out
    [[ "$status" -eq 3 ]]
}
