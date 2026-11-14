#!/bin/sh
set -eu

CERT_NAME="${1:-Talus Local Code Signing}"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
[ -f "$LOGIN_KEYCHAIN" ] || LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain"

existing_id="$(security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null | grep -F "\"$CERT_NAME\"" | head -n 1 | awk '{print $2}' || true)"
if [ -n "$existing_id" ]; then
    echo "Certificate '$CERT_NAME' is already installed and trusted ($existing_id)."
    exit 0
fi

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/talus-cert.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

if security find-certificate -c "$CERT_NAME" -p "$LOGIN_KEYCHAIN" >"$TMPD/cert.pem" 2>/dev/null && [ -s "$TMPD/cert.pem" ]; then
    echo "Found existing '$CERT_NAME' certificate in $LOGIN_KEYCHAIN; configuring Code Signing trust..."
else
    echo "Generating 10-year local code signing certificate '$CERT_NAME'..."
    cat >"$TMPD/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_codesign
prompt = no

[dn]
CN = $CERT_NAME
O = Talus Local

[v3_codesign]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

    PASS="$(/usr/bin/openssl rand -hex 16)"
    /usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
        -keyout "$TMPD/key.pem" \
        -out "$TMPD/cert.pem" \
        -days 3650 \
        -config "$TMPD/openssl.cnf" 2>/dev/null

    /usr/bin/openssl pkcs12 -export \
        -out "$TMPD/cert.p12" \
        -inkey "$TMPD/key.pem" \
        -in "$TMPD/cert.pem" \
        -name "$CERT_NAME" \
        -passout "pass:$PASS"

    security import "$TMPD/cert.p12" \
        -k "$LOGIN_KEYCHAIN" \
        -P "$PASS" \
        -T /usr/bin/codesign >/dev/null
    echo "Imported '$CERT_NAME' into $LOGIN_KEYCHAIN."
fi

echo "Requesting macOS authorization to trust '$CERT_NAME' for Code Signing ONLY..."
security add-trusted-cert -r trustAsRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$TMPD/cert.pem"

verified_id="$(security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null | grep -F "\"$CERT_NAME\"" | head -n 1 | awk '{print $2}' || true)"
if [ -z "$verified_id" ]; then
    echo "Error: '$CERT_NAME' is not yet listed as a valid code signing identity." >&2
    exit 1
fi
echo "Ready: '$CERT_NAME' ($verified_id) is trusted for Code Signing."
