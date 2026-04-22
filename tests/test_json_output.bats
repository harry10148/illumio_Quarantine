#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

@test "json parses with jq" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    assert_success
    echo "$output" | jq -e '.' >/dev/null
}

@test "json contains all required fields" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    assert_success
    for f in audit_id correlation_id mode label requested_targets \
             search_strategy matched updated skipped_already_labeled \
             failed counts parallel dry_run duration_ms exit_code; do
        echo "$output" | jq -e ".${f}" >/dev/null || { echo "missing $f"; false; }
    done
}

@test "counts match arrays" {
    run bash "$SCRIPT" --targets "10.0.0.5,nonexistent.host" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    assert_success
    a=$(echo "$output" | jq '.matched | length')
    b=$(echo "$output" | jq '.counts.matched')
    [[ "$a" == "$b" ]]
}

@test "correlation_id echoes input" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json --correlation-id "MY-9"
    assert_success
    [[ "$(echo "$output" | jq -r '.correlation_id')" == "MY-9" ]]
}

@test "human logs suppressed with --json" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    assert_success
    refute_output --partial "DRY-RUN"
    refute_output --partial "illumio_Quarantine"
}
