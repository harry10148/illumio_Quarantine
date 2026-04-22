#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

_run_json() {
    local out
    out=$(bash "$SCRIPT" "$@")
    echo "$out"
}

@test "--label-id resolves via GET /labels/:id and reports key/value" {
    run bash "$SCRIPT" --targets "server1.lab.local" --label-id 878 \
        --non-interactive --dry-run --json
    assert_success
    [[ "$(echo "$output" | jq -r '.label.key')"   == "Quarantine" ]]
    [[ "$(echo "$output" | jq -r '.label.value')" == "Severe"     ]]
    [[ "$(echo "$output" | jq -r '.label.href')"  == "/orgs/1/labels/878" ]]
}

@test "--label-key+--label-value resolves via GET /labels?key=..." {
    run bash "$SCRIPT" --targets "server1.lab.local" \
        --label-key Quarantine --label-value Severe \
        --non-interactive --dry-run --json
    assert_success
    [[ "$(echo "$output" | jq -r '.label.href')" == "/orgs/1/labels/878" ]]
}

@test "--label-key+--label-value not found exits 5" {
    run bash "$SCRIPT" --targets "server1.lab.local" \
        --label-key Quarantine --label-value NoSuch \
        --non-interactive --dry-run --json
    assert_failure 5
    assert_output --partial "no label with key=Quarantine value=NoSuch"
}

@test "append mode strips existing same-key labels before adding target (B2)" {
    # server1 has role:web (href 100) and Quarantine:Mild (href 700).
    # We apply Quarantine:Severe (href 878). Expected PUT body contains role:web
    # and Quarantine:Severe but NOT Quarantine:Mild.
    run bash "$SCRIPT" --targets "server1.lab.local" --label-id 878 \
        --mode append --non-interactive --json
    assert_success

    # Grab last PUT body from the mock log
    put_body=$(awk -F'\t' '$1=="PUT"{print $3}' "$MOCK_CURL_LOG" | tail -n1)
    hrefs=$(echo "$put_body" | jq -r '.labels[].href' | sort)
    [[ "$(echo "$hrefs" | grep -c '/orgs/1/labels/100')" == "1" ]]
    [[ "$(echo "$hrefs" | grep -c '/orgs/1/labels/700')" == "0" ]]   # Mild stripped
    [[ "$(echo "$hrefs" | grep -c '/orgs/1/labels/878')" == "1" ]]   # Severe added
}

@test "overwrite mode keeps only the target label" {
    run bash "$SCRIPT" --targets "server1.lab.local" --label-id 878 \
        --mode overwrite --non-interactive --json
    assert_success
    put_body=$(awk -F'\t' '$1=="PUT"{print $3}' "$MOCK_CURL_LOG" | tail -n1)
    [[ "$(echo "$put_body" | jq '.labels | length')" == "1" ]]
    [[ "$(echo "$put_body" | jq -r '.labels[0].href')" == "/orgs/1/labels/878" ]]
}

@test "--label-key with space URL-encodes the query" {
    # Mock curl doesn't have a fixture for "key=Quar%20antine", so this just
    # verifies the encoded form reaches the log; resolve_target_label will
    # exit 5 since no label matches, which is fine for this check.
    run bash "$SCRIPT" --targets "server1.lab.local" \
        --label-key "Q K" --label-value "V V" \
        --non-interactive --dry-run --json
    # Expect resolver to exit 5 (no match against the non-existent "Q K" key)
    assert_failure 5
    # Verify the URL in the mock curl log has the %-encoded key
    run grep -F "labels?key=Q%20K" "$MOCK_CURL_LOG"
    assert_success
}

@test "--label-id flow exits 4 when same-key labels query auth-fails" {
    export MOCK_CURL_AUTH_FAIL_LABELS_KEY="1"
    run bash "$SCRIPT" --targets "server1.lab.local" --label-id 878 \
        --non-interactive --dry-run --json
    assert_failure 4
    assert_output --partial "authentication failed"
}
