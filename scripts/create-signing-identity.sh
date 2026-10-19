#!/bin/zsh
# Creates a self-signed "Prism Local Signing" identity in the login keychain.
# Ad-hoc signatures change on every build, so Keychain forgets "Always Allow" for the Gemini key;
# a stable identity keeps that grant across rebuilds. Remove with Keychain Access if no longer needed.
set -euo pipefail
name="Prism Local Signing"
if security find-identity -p codesigning | grep -q "$name"; then echo "$name already exists"; exit 0; fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$name
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" -days 3650 -config "$work/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/id.p12" -passout pass:prism -name "$name" 2>/dev/null ||
  openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/id.p12" -passout pass:prism -name "$name"
security import "$work/id.p12" -k ~/Library/Keychains/login.keychain-db -P prism -T /usr/bin/codesign
echo "Created $name"
