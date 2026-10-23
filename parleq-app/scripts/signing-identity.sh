#!/usr/bin/env bash
# Release signing-identity helper (issue #122: Apple's original Developer ID CA
# expires 2027-02-01; releases must be signed by a Developer ID (G2) cert).
#
#   signing-identity.sh select
#       Print the SHA-1 of the best "Developer ID Application:" identity:
#       G2-issued + unexpired first, then any unexpired, then any. Prints
#       nothing (exit 0) when none exists. Read-only keychain query.
#   signing-identity.sh check [identity]
#       Release gate. identity defaults to $PARLEQ_CODESIGN_IDENTITY, then
#       `select`. Exits 1 unless the cert is G2-issued, unexpired. Warns when
#       it expires within 60 days. Escape hatch: PARLEQ_ALLOW_NON_G2=1 turns
#       the failure into a warning.
#   signing-identity.sh verify <path>
#       After signing: the leaf cert that signed <path> (.app or .dmg) must be
#       G2-issued (same escape hatch).
set -euo pipefail

WARN_DAYS=60
TMP="$(mktemp -d "${TMPDIR:-/tmp}/parleq-sign.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Dump every "Developer ID Application" cert in the keychain to $TMP/<SHA1>.pem
dump_certs() {
    security find-certificate -a -Z -p -c "Developer ID Application" 2>/dev/null |
        awk -v d="$TMP" '
            /^SHA-1 hash:/ {h=$3}
            /BEGIN CERTIFICATE/ {f=d "/" h ".pem"}
            f {print > f}
            /END CERTIFICATE/ {close(f); f=""}'
}

is_g2() { openssl x509 -noout -issuer -in "$1" 2>/dev/null | grep -Eq 'OU ?= ?G2|\(G2\)|G2 Sub'; }
not_expired() { openssl x509 -noout -checkend 0 -in "$1" >/dev/null 2>&1; }

# Candidate SHA-1s from valid codesigning identities
candidates() {
    security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application:/{print $2}'
}

select_identity() {
    dump_certs
    local h first="" unexpired=""
    for h in $(candidates); do
        local p="$TMP/$h.pem"
        [[ -f "$p" ]] || continue
        [[ -z "$first" ]] && first="$h"
        if not_expired "$p"; then
            [[ -z "$unexpired" ]] && unexpired="$h"
            if is_g2 "$p"; then echo "$h"; return 0; fi
        fi
    done
    echo "${unexpired:-$first}"
}

# Resolve a hash or display name to a PEM path in $TMP; prints path or nothing.
pem_for() {
    local id="$1"
    if [[ "$id" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        dump_certs
        local up; up="$(echo "$id" | tr a-f A-F)"
        [[ -f "$TMP/$up.pem" ]] && echo "$TMP/$up.pem"
    else
        security find-certificate -c "$id" -p > "$TMP/byname.pem" 2>/dev/null || true
        [[ -s "$TMP/byname.pem" ]] && echo "$TMP/byname.pem"
    fi
    return 0
}

fail_or_warn() {
    if [[ "${PARLEQ_ALLOW_NON_G2:-}" == "1" ]]; then
        echo "WARNING: $1 (continuing: PARLEQ_ALLOW_NON_G2=1)" >&2
    else
        {
            echo "ERROR: $1"
            echo "  Releases must be signed with a Developer ID Application cert issued by the"
            echo "  'Developer ID Certification Authority (G2)' (see issue #122; the original"
            echo "  CA expires 2027-02-01). Install the G2 cert, remove the old one from the"
            echo "  keychain, or pass CODESIGN_IDENTITY=<G2 cert SHA-1>."
            echo "  Escape hatch (not for real releases): PARLEQ_ALLOW_NON_G2=1"
        } >&2
        exit 1
    fi
}

cmd="${1:-}"
case "$cmd" in
select) select_identity ;;
check)
    id="${2:-${PARLEQ_CODESIGN_IDENTITY:-}}"
    [[ -z "$id" ]] && id="$(select_identity)"
    if [[ -z "$id" || "$id" == "-" ]]; then
        echo "ERROR: no Developer ID Application identity available for a release build." >&2
        exit 1
    fi
    pem="$(pem_for "$id")"
    if [[ -z "$pem" ]]; then fail_or_warn "cannot read certificate for identity '$id' from the keychain"; exit 0; fi
    end="$(openssl x509 -noout -enddate -in "$pem" | cut -d= -f2)"
    ok=1
    if ! not_expired "$pem"; then ok=0; fail_or_warn "signing certificate '$id' expired ($end)"; fi
    if ! is_g2 "$pem"; then
        ok=0
        fail_or_warn "signing certificate '$id' is NOT issued by Developer ID Certification Authority (G2)"
    fi
    if ! openssl x509 -noout -checkend $((WARN_DAYS * 86400)) -in "$pem" >/dev/null 2>&1; then
        echo "WARNING: signing certificate '$id' expires $end (within $WARN_DAYS days); renew it (G2 certs last 1 year)." >&2
    fi
    if [[ $ok == 1 ]]; then echo "==> signing identity OK: $id (G2, expires $end)" >&2; fi
    ;;
verify)
    target="${2:?usage: verify <path>}"
    target="$(cd "$(dirname "$target")" && pwd)/$(basename "$target")"
    (cd "$TMP" && codesign -d --extract-certificates "$target" >/dev/null 2>&1) || {
        fail_or_warn "could not read signing certificates from $target"; exit 0; }
    # codesign0 is the leaf; convert DER to PEM
    openssl x509 -inform DER -in "$TMP/codesign0" -out "$TMP/leaf.pem" 2>/dev/null ||
        { fail_or_warn "could not parse leaf certificate of $target"; exit 0; }
    if is_g2 "$TMP/leaf.pem"; then
        echo "==> verified: $(basename "$target") signed by a G2-issued Developer ID certificate" >&2
    else
        fail_or_warn "$(basename "$target") was NOT signed by a G2-issued certificate"
    fi
    ;;
*) echo "usage: $0 select | check [identity] | verify <path>" >&2; exit 2 ;;
esac
