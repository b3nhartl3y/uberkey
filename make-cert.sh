#!/bin/bash
# Creates a self-signed code-signing identity so that rebuilding Uberkey no longer
# invalidates its Accessibility grant.
#
# TCC records an app's *designated requirement*. Ad-hoc signing makes that the cdhash,
# which changes on every build — hence the grant dying each time, while the checkbox
# stayed on. Signing with a stable certificate makes the requirement
#   identifier "agency.honcho.uberkey" and certificate leaf = H"<cert hash>"
# which is identical across rebuilds, so the grant sticks. Run once.
set -euo pipefail

CN="${UBERKEY_CERT_CN:-Uberkey Self-Signed}"
KEYCHAIN="${UBERKEY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
DAYS=3650
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "$CN"; then
  echo "Identity already present: $CN"
  exit 0
fi

cat > "$TMP/ext.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $CN
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -sha256 -days "$DAYS" -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -config "$TMP/ext.cnf" -extensions v3 2>/dev/null

# macOS Security cannot read OpenSSL 3's default PKCS#12 encryption, and disagrees with it
# about empty passwords — hence the legacy PBE algorithms and a throwaway password.
PW="$(openssl rand -hex 16)"
openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -passout "pass:$PW" -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -legacy 2>/dev/null

# -A / -T codesign let codesign use the private key without a keychain prompt per build.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PW" -A -T /usr/bin/codesign

# Until it is trusted for code signing the identity is not "valid" and codesign -s cannot
# find it by name. The user trust domain needs no admin password.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "Created identity: $CN"
security find-identity -v -p codesigning "$KEYCHAIN" | grep "$CN"
