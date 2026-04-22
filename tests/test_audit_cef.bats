#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

@test "audit file created with CEF header" {
    local f="$BATS_TMPDIR_LOCAL/a.cef"
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json \
        --correlation-id "INC-A" --reason "bats" --audit-file "$f"
    assert_success
    run cat "$f"
    assert_output --partial "CEF:0|Illumio|Quarantine|1.3.0|quarantine.action"
    assert_output --partial "cs1=INC-A"
    assert_output --partial "cs3=bats"
    assert_output --partial "cs5=Quarantine"
    assert_output --partial "cs6=Severe"
    assert_output --partial "cs7=true"
}

@test "escaping of | and = in reason" {
    local f="$BATS_TMPDIR_LOCAL/a.cef"
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json \
        --reason "rule|a=b" --audit-file "$f"
    run cat "$f"
    assert_output --partial 'cs3=rule\|a\=b'
}

@test "outcome=no_match when nothing matches" {
    local f="$BATS_TMPDIR_LOCAL/a.cef"
    run bash "$SCRIPT" --targets "192.0.2.99" --label-id 878 \
        --mode append --non-interactive --dry-run --json --audit-file "$f"
    [[ "$status" -eq 3 ]]
    run cat "$f"
    assert_output --partial "outcome=no_match"
}

@test "flock prevents interleaving of concurrent writers" {
    local f="$BATS_TMPDIR_LOCAL/a.cef"
    for i in $(seq 1 10); do
        bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
            --mode append --non-interactive --dry-run --json \
            --reason "run-$i" --audit-file "$f" >/dev/null &
    done
    wait
    run awk '!/^CEF:0\|/{print "BAD:" $0}' "$f"
    assert_output ""
    run wc -l < "$f"
    assert_output "10"
}

@test "no audit file when --audit-file omitted" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    assert_success
}
