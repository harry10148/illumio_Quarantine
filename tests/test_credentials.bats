#!/usr/bin/env bats
load 'helpers/setup.bash'
setup() { _load_libs; common_setup; }
teardown() { common_teardown; }

@test "reads credentials from --credentials-file" {
    cat > "$BATS_TMPDIR_LOCAL/creds.conf" <<EOF
API_USER="file_user"
API_PASS="file_pass"
EOF
    chmod 600 "$BATS_TMPDIR_LOCAL/creds.conf"
    unset ILLUMIO_QUARANTINE_API_USER ILLUMIO_QUARANTINE_API_PASS
    run bash "$SCRIPT" --targets "server1.lab.local" --label-id 878 \
        --non-interactive --dry-run --json \
        --credentials-file "$BATS_TMPDIR_LOCAL/creds.conf"
    assert_success
}

@test "env vars used when no credentials-file" {
    run bash "$SCRIPT" --targets "server1.lab.local" --label-id 878 \
        --non-interactive --dry-run --json
    assert_success
}

@test "CLI --pce-url beats env beats credentials-file (precedence G)" {
    cat > "$BATS_TMPDIR_LOCAL/creds.conf" <<EOF
API_USER="u"; API_PASS="p"
PCE_URL_BASE="https://pce-file.local:8443"
EOF
    chmod 600 "$BATS_TMPDIR_LOCAL/creds.conf"
    unset ILLUMIO_QUARANTINE_API_USER ILLUMIO_QUARANTINE_API_PASS
    export ILLUMIO_QUARANTINE_PCE_URL="https://pce-env.local:8443"
    run bash "$SCRIPT" --targets "server1.lab.local" --label-id 878 \
        --non-interactive --dry-run --json \
        --credentials-file "$BATS_TMPDIR_LOCAL/creds.conf" \
        --pce-url "https://pce-cli.local:8443"
    assert_success
    run grep -c 'pce-cli.local' "$MOCK_CURL_LOG"
    refute_output "0"
    run grep -c 'pce-env.local' "$MOCK_CURL_LOG"
    assert_output "0"
}

@test "exits 6 if non-interactive with no creds" {
    unset ILLUMIO_QUARANTINE_API_USER ILLUMIO_QUARANTINE_API_PASS
    run bash "$SCRIPT" --targets "server1.lab.local" --label-id 878 \
        --non-interactive --dry-run --json
    assert_failure 6
}

@test "auto-discovers conf at ~/.config/illumio_quarantine/quarantine.conf" {
    mkdir -p "$HOME/.config/illumio_quarantine"
    cat > "$HOME/.config/illumio_quarantine/quarantine.conf" <<EOF
API_USER="auto_user"
API_PASS="auto_pass"
EOF
    chmod 600 "$HOME/.config/illumio_quarantine/quarantine.conf"

    unset ILLUMIO_QUARANTINE_API_USER ILLUMIO_QUARANTINE_API_PASS
    run bash "$SCRIPT" --targets "server1.lab.local" --label-id 878 \
        --non-interactive --dry-run --json
    assert_success
}

@test "warns on world-readable credentials file" {
    cat > "$BATS_TMPDIR_LOCAL/c.conf" <<EOF
API_USER="u"; API_PASS="p"
EOF
    chmod 644 "$BATS_TMPDIR_LOCAL/c.conf"
    unset ILLUMIO_QUARANTINE_API_USER ILLUMIO_QUARANTINE_API_PASS
    run bash "$SCRIPT" --targets "10.0.0.5" --label-id 878 \
        --non-interactive --dry-run --json \
        --credentials-file "$BATS_TMPDIR_LOCAL/c.conf"
    assert_success
    [[ "$output" == *"insecure permissions"* ]] || [[ "$stderr" == *"insecure permissions"* ]]
}
