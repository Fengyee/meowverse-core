#!/bin/zsh
# Local Background Assets server for the cats' 低 asset packs (docs/CAT_PACK.md "按需下载";
# Apple: "Testing asset packs locally"). ios/README.md "画质" has the whole flow.
#
#   ./ba-local.sh stage [--tier-source DIR]   stage + ba-package every cat's tiers into build/asset-packs
#   ./ba-local.sh certs                 throwaway CA and localhost identity (build/ba-local)
#   ./ba-local.sh sim <udid>            trust the CA in that simulator, point its BA override here
#   ./ba-local.sh serve                 ba-serve build/asset-packs/*.aar on https://localhost:54753
#   ./ba-local.sh clean [<udid>]        take the identity off the keychain list, clear the override
#
# The identity sits in its own keychain file under build/ba-local, put on the user keychain search
# list (ba-serve only looks there) and taken off by `clean`; the login keychain and the Mac's
# trust settings are not touched. The CA is trusted only inside the simulator you name. On a
# device, ba-serve needs a certificate for the Mac's LAN name or address instead of localhost,
# the CA installed and trusted as a profile, and Settings > Developer > Background Assets
# Testing > Development Overrides > URL Override (README).
set -euo pipefail
cd "${0:A:h}"
D=build/ba-local
KC=$PWD/$D/ba-local.keychain-db
PORT=54753
PASS=ba-local

case "${1:-}" in
  stage)
    shift
    (cd .. && node scripts/ios/bake-ios-assets.mjs --asset-packs ios/build/asset-packs "$@")
    for m in build/asset-packs/manifests/*.json(N); do
      xcrun ba-package "$PWD/$m" -o "$PWD/build/asset-packs/${m:t:r}.aar"
    done
    ;;
  certs)
    mkdir -p $D
    printf '[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=ca\n[dn]\nCN=Meowverse BA local CA\n[ca]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n' > $D/ca.cnf
    printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=localhost\n[leaf]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n' > $D/leaf.cnf
    openssl req -x509 -newkey rsa:2048 -nodes -keyout $D/ca.key -out $D/ca.pem -days 30 -sha256 -config $D/ca.cnf 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -keyout $D/leaf.key -out $D/leaf.csr -config $D/leaf.cnf 2>/dev/null
    openssl x509 -req -in $D/leaf.csr -CA $D/ca.pem -CAkey $D/ca.key -CAcreateserial -out $D/leaf.pem -days 30 -sha256 -extfile $D/leaf.cnf -extensions leaf 2>/dev/null
    # macOS `security import` reads only the legacy PKCS#12 encryption.
    openssl pkcs12 -export -legacy -inkey $D/leaf.key -in $D/leaf.pem -certfile $D/ca.pem -out $D/leaf.p12 -passout pass:$PASS -name localhost
    security delete-keychain $KC 2>/dev/null || true
    security create-keychain -p $PASS $KC
    security set-keychain-settings $KC
    security unlock-keychain -p $PASS $KC
    # -A: any app may use this throwaway key without asking; without it ba-serve stops with
    # "User canceled the operation" (the access prompt it cannot show).
    security import $D/leaf.p12 -k $KC -P $PASS -A
    security set-key-partition-list -S apple-tool:,apple:,unsigned: -s -k $PASS $KC > /dev/null
    current=("${(@f)$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//' | grep -v -F $KC)}")
    security list-keychains -d user -s "${current[@]}" $KC
    security find-identity -p ssl-server $KC | head -3
    ;;
  sim)
    udid=${2:?udid}
    xcrun simctl keychain $udid add-root-cert $D/ca.pem
    # What Settings > Developer > Background Assets Testing > URL Override writes on a device.
    xcrun simctl spawn $udid defaults write com.apple.backgroundassets.managed MBAURLOverride "https://localhost:$PORT"
    ;;
  serve)
    security unlock-keychain -p $PASS $KC
    exec xcrun ba-serve --host localhost --port $PORT --choose-identity-automatically build/asset-packs/*.aar
    ;;
  clean)
    current=("${(@f)$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//' | grep -v -F $KC)}")
    security list-keychains -d user -s "${current[@]}"
    security delete-keychain $KC 2>/dev/null || true
    [[ -n "${2:-}" ]] && xcrun simctl spawn $2 defaults delete com.apple.backgroundassets.managed MBAURLOverride 2>/dev/null || true
    security list-keychains -d user
    ;;
  *) sed -n '2,16p' "$0"; exit 64 ;;
esac
