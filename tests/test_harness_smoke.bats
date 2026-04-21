#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

@test "mock curl returns workloads list" {
    run curl -s "${ILLUMIO_QUARANTINE_PCE_URL}/api/v2/orgs/1/workloads"
    assert_success
    assert_output --partial "server1.lab.local"
}

@test "mock curl PUT returns 204" {
    run curl -s -X PUT -d '{}' "${ILLUMIO_QUARANTINE_PCE_URL}/api/v2/orgs/1/workloads/x"
    assert_success
    assert_output "204"
}

@test "mock curl ?ip_address=10.0.0.5 returns 1 workload" {
    run curl -s "${ILLUMIO_QUARANTINE_PCE_URL}/api/v2/orgs/1/workloads?ip_address=10.0.0.5"
    assert_success
    echo "$output" | jq -e 'length == 1' >/dev/null
}
