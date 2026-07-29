#!/bin/bash
# Creates a self-signed code-signing certificate ("Bluejay Wispr Dev") in the login
# keychain so the app's signing identity stays stable across rebuilds — that way macOS
# TCC keeps the Accessibility/Microphone grants instead of invalidating them every build
# (which is what happens with plain ad-hoc signatures).
#
# One-time GUI interactions you may see:
#  - a prompt to allow modifying certificate trust settings
#  - on the first codesign/launch, "codesign wants to access key…" → click "Always Allow"
set -euo pipefail

CN="Bluejay Wispr Dev"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"; then
    echo "Signing identity \"$CN\" already exists."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/ext.cnf" <<EOF
[req]
distinguished_name = dn
[dn]
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

# System LibreSSL: Homebrew OpenSSL 3 emits PKCS12 encryption `security import` can't read.
OPENSSL=/usr/bin/openssl

$OPENSSL req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -subj "/CN=$CN" -config "$TMP/ext.cnf" -extensions ext

$OPENSSL pkcs12 -export -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout pass:bjwispr -name "$CN" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

# -A: no keychain ACL prompts for this key (local dev cert; codesign would otherwise
# fail with errSecInternalComponent when run non-interactively).
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db \
    -P bjwispr -A

# Trust the cert for code signing (user trust domain).
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"

if security find-identity -v -p codesigning | grep -q "$CN"; then
    echo "Created signing identity \"$CN\"."
else
    echo "WARNING: identity created but not yet valid for codesigning (trust step may need GUI approval)." >&2
    exit 1
fi
