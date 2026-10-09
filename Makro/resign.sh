#!/bin/bash
# Post-build resign: injects the full profile entitlementments (incl.
# aps-environment) into the signed app.
#
# WHY this exists: Xcode 26's automatic-signing entitlement derivation
# silently drops aps-environment for xcodegen-generated projects (classic
# PBXGroup layout) — ProcessProductEntitlements never runs, so the .xcent
# derived at signing time lacks push even though the entitlements file and
# provisioning profile both carry it. Re-signing directly from the embedded
# profile's entitlements is deterministic and version-proof.
#
# Usage: resign.sh <path-to-Makro.app> [certificate-hash]
#   certificate-hash defaults to the single valid "Apple Development" identity.
set -euo pipefail

APP="${1:?usage: resign.sh <Makro.app> [cert-sha1]}"
CERT="${2:-}"

if [ -z "$CERT" ]; then
    # Line format: "  2) 4F754AD9… \"Apple Development: …\"" — $2 is the SHA-1.
    CERT=$(security find-identity -v -p codesigning \
        | grep "Apple Development" | grep -v "CSSMERR" \
        | head -1 | awk '{print $2}')
fi
[ -n "$CERT" ] || { echo "resign: no valid Apple Development identity found" >&2; exit 1; }

# Extract the entitlements the profile actually grants (aps-environment,
# keychain groups, ...) — the source of truth Apple itself signed.
PROF="$APP/embedded.mobileprovision"
[ -f "$PROF" ] || { echo "resign: $PROF missing (not a device build?)" >&2; exit 1; }
ENT=$(mktemp /tmp/makro-ent.XXXXXX.plist)
trap 'rm -f "$ENT"' EXIT
security cms -D -i "$PROF" | plutil -extract Entitlements xml1 -o "$ENT" -

codesign -f --sign "$CERT" --entitlements "$ENT" --generate-entitlement-der "$APP"

# Verify: fail loudly if push entitlement didn't land.
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q aps-environment; then
    echo "resign: OK — aps-environment present (cert ${CERT:0:8}…)"
else
    echo "resign: FAILED — aps-environment still missing after resign" >&2
    exit 2
fi
