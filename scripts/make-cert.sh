#!/bin/zsh
# Cria (uma vez) o certificado local "Seed Dev" para assinar o Seed.app com
# identidade ESTÁVEL — assim o macOS preserva as permissões (TCC) entre builds.
set -e

if security find-identity -v -p codesigning 2>/dev/null | grep -q "Seed Dev"; then
    echo "✓ certificado 'Seed Dev' já existe"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -subj "/CN=Seed Dev" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# -legacy: o formato PKCS12 padrão do OpenSSL 3 não é aceito pelo keychain
openssl pkcs12 -export -legacy -out "$TMP/seed.p12" -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" -passout pass:seed-dev -name "Seed Dev" 2>/dev/null \
|| openssl pkcs12 -export -out "$TMP/seed.p12" -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" -passout pass:seed-dev -name "Seed Dev"

security import "$TMP/seed.p12" -k ~/Library/Keychains/login.keychain-db \
    -P seed-dev -T /usr/bin/codesign

# marca o cert como confiável para code signing (pode pedir sua senha uma vez)
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"

echo "✓ certificado 'Seed Dev' criado e confiável"
security find-identity -v -p codesigning | grep "Seed Dev" || true
