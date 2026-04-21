#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

@test "--help prints usage and exits 0" {
    run bash "$SCRIPT" --help
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "--targets"
    assert_output --partial "--label-id"
    assert_output --partial "--label-key"
    assert_output --partial "--parallel"
}

@test "--version prints 1.3.0" {
    run bash "$SCRIPT" --version
    assert_success
    assert_output --partial "1.3.0"
}

@test "non-interactive without --targets exits 5" {
    run bash "$SCRIPT" --label-id 878 --non-interactive --dry-run --json
    assert_failure 5
}

@test "non-interactive without any label id/key exits 5" {
    run bash "$SCRIPT" --targets 10.0.0.5 --non-interactive --dry-run --json
    assert_failure 5
}

@test "non-interactive with --label-key without --label-value exits 5" {
    run bash "$SCRIPT" --targets x --label-key Quarantine --non-interactive --dry-run --json
    assert_failure 5
}

@test "both --label-id and --label-key warns but accepts (id wins)" {
    run bash "$SCRIPT" --targets 10.0.0.5 --label-id 878 \
        --label-key Quarantine --label-value Severe \
        --non-interactive --dry-run --json
    assert_success
    assert_output --partial "--label-id takes precedence"
}

@test "unknown flag exits 5" {
    run bash "$SCRIPT" --nope --non-interactive
    assert_failure 5
    assert_output --partial "unknown option"
}

@test "--parallel must be 1..20" {
    run bash "$SCRIPT" --targets x --label-id 1 --parallel 0 --non-interactive --dry-run --json
    assert_failure 5
    run bash "$SCRIPT" --targets x --label-id 1 --parallel 21 --non-interactive --dry-run --json
    assert_failure 5
}

@test "non-interactive does not prompt for confirmation or mode" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --mode append --non-interactive --dry-run --json
    assert_success
    refute_output --partial "Continue?"
}

@test "correlation-id and reason appear in header in human mode" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --non-interactive --dry-run \
        --correlation-id "INC-42" --reason "test rule"
    assert_success
    assert_output --partial "correlation_id=INC-42"
    assert_output --partial "reason=test rule"
}

@test "--json without --non-interactive exits 5" {
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 --json
    assert_failure 5
    assert_output --partial "--json requires --non-interactive"
}
