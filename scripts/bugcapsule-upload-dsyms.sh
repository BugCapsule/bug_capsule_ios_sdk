#!/bin/sh
# Uploads the dSYMs of an Xcode build to BugCapsule so crash frames are
# symbolicated server-side (monitoring-v1 §5.4:
# POST /v1/debug-files?kind=dsym&debugId=<UUID>&arch=<arch>&name=<file>).
#
# Xcode: add a Run Script build phase after "Embed Frameworks" (Release /
# archive builds; set DEBUG_INFORMATION_FORMAT = dwarf-with-dsym):
#
#   "${BUILD_DIR%/Build/*}/SourcePackages/checkouts/bug_capsule_ios_sdk/scripts/bugcapsule-upload-dsyms.sh"
#
# and add "${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Resources/DWARF/${TARGET_NAME}"
# to its Input Files so it runs after the dSYM exists. Or run it by hand / in CI:
#
#   BUGCAPSULE_URL=https://bugcapsule.example.com BUGCAPSULE_SECRET_KEY=bcs_... \
#     scripts/bugcapsule-upload-dsyms.sh path/to/App.xcarchive/dSYMs
#
# Environment:
#   BUGCAPSULE_URL          backend base URL (required)
#   BUGCAPSULE_SECRET_KEY   project secret key bcs_... (required; CI secret, never in the app)
#   BUGCAPSULE_DSYM_PATHS   directories or .dSYM bundles (default: $1..., else
#                           $DWARF_DSYM_FOLDER_PATH from Xcode)
#   BUGCAPSULE_ALLOW_FAILURE=1  never fail the build on upload errors (default 1 in Xcode)
#   BUGCAPSULE_SKIP_DEBUG=1     skip Debug configuration builds (default 1)
#
# Each DWARF file is uploaded once per UUID (one per architecture slice),
# gzip-compressed. Re-uploading the same UUID replaces the file.
set -u

log() { echo "bugcapsule-upload-dsyms: $*"; }
fail() {
  log "error: $*" >&2
  if [ "${BUGCAPSULE_ALLOW_FAILURE:-${XCODE_VERSION_ACTUAL:+1}}" = "1" ]; then exit 0; fi
  exit 1
}

if [ "${BUGCAPSULE_SKIP_DEBUG:-1}" = "1" ] && [ "${CONFIGURATION:-}" = "Debug" ]; then
  log "Debug configuration: skipped (BUGCAPSULE_SKIP_DEBUG=0 to upload)"
  exit 0
fi

url=${BUGCAPSULE_URL:-}
key=${BUGCAPSULE_SECRET_KEY:-}
[ -n "$url" ] || fail "BUGCAPSULE_URL is not set"
[ -n "$key" ] || fail "BUGCAPSULE_SECRET_KEY is not set"
case "$key" in
  bci_*) fail "BUGCAPSULE_SECRET_KEY is an ingest key; debug file uploads need the secret key (bcs_...)" ;;
esac
url=${url%/}

if [ "$#" -eq 0 ]; then
  if [ -n "${BUGCAPSULE_DSYM_PATHS:-}" ]; then
    # shellcheck disable=SC2086 # space-separated list by design
    set -- $BUGCAPSULE_DSYM_PATHS
  elif [ -n "${DWARF_DSYM_FOLDER_PATH:-}" ]; then
    set -- "$DWARF_DSYM_FOLDER_PATH"
  else
    fail "no dSYM path (pass a directory, set BUGCAPSULE_DSYM_PATHS, or run from an Xcode build phase)"
  fi
fi

command -v dwarfdump >/dev/null 2>&1 || fail "dwarfdump not found (install the Xcode command line tools)"
command -v curl >/dev/null 2>&1 || fail "curl not found"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bugcapsule-dsym.XXXXXX") || fail "cannot create a temp directory"
trap 'rm -rf "$tmp"' EXIT INT TERM

uploaded=0
failed=0

upload_dwarf() {
  dwarf=$1
  name=$(basename "$dwarf")
  gz="$tmp/$name.gz"
  gzip -c "$dwarf" >"$gz" || { echo failed >>"$tmp/results"; return; }
  # "UUID: 6A1B0C6E-... (arm64) /path/to/DWARF/App"
  dwarfdump --uuid "$dwarf" 2>/dev/null | while read -r _ uuid arch _rest; do
    uuid=$(echo "$uuid" | tr 'A-Z' 'a-z')
    arch=$(echo "$arch" | tr -d '()')
    [ -n "$uuid" ] || continue
    status=$(curl -sS -o "$tmp/response" -w '%{http_code}' -X POST \
      -H "Authorization: Bearer $key" \
      -H "Content-Type: application/octet-stream" \
      -H "Content-Encoding: gzip" \
      --data-binary "@$gz" \
      "$url/v1/debug-files?kind=dsym&debugId=$uuid&arch=$arch&name=$name") || status=000
    if [ "$status" = "200" ] || [ "$status" = "201" ]; then
      log "uploaded $name $arch $uuid"
      echo ok >>"$tmp/results"
    else
      log "upload of $name $arch $uuid failed: HTTP $status $(head -c 300 "$tmp/response" 2>/dev/null)" >&2
      echo failed >>"$tmp/results"
    fi
  done
}

for root in "$@"; do
  [ -e "$root" ] || { log "skipping missing $root"; continue; }
  find "$root" -path '*.dSYM/Contents/Resources/DWARF/*' -type f 2>/dev/null | while IFS= read -r dwarf; do
    upload_dwarf "$dwarf"
  done
done

if [ -f "$tmp/results" ]; then
  uploaded=$(grep -c '^ok$' "$tmp/results" || true)
  failed=$(grep -c '^failed$' "$tmp/results" || true)
fi
log "$uploaded uploaded, $failed failed"
[ "$uploaded" -gt 0 ] || [ "$failed" -eq 0 ] || fail "no dSYM could be uploaded"
[ "$failed" -eq 0 ] || fail "$failed upload(s) failed"
exit 0
