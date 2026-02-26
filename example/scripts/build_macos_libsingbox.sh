#!/usr/bin/env bash
set -euo pipefail

SINGBOX_REPO_URL="https://github.com/SagerNet/sing-box.git"
SINGBOX_REF="latest"
PROJECT_ROOT="$(pwd)"
SINGBOX_DIR=""
KEEP_SOURCE=false
TMP_DIR=""
MACOS_ARCHES="arm64,amd64"
BUILD_TMP=""
SINGBOX_VERSION=""
DEFAULT_BUILD_TAGS="with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,with_tailscale,with_ccm,with_ocm,badlinkname,tfogo_checklinkname0"
SINGBOX_BUILD_TAGS="${SINGBOX_BUILD_TAGS:-$DEFAULT_BUILD_TAGS}"

usage() {
  cat <<'EOF'
Usage: build_macos_libsingbox.sh [options]

Build macOS sing-box binary from SagerNet/sing-box and place it in:
  macos/Frameworks/sing-box

Options:
  --project-root <path>      Flutter app root (default: current directory)
  --singbox-dir <path>       Use an existing local sing-box directory
  --singbox-ref <ref|main|latest> sing-box git ref to use when auto-cloning (default: latest release tag)
  --singbox-repo <url>       sing-box git repo URL (default: https://github.com/SagerNet/sing-box.git)
  --macos-arches <list>      Comma-separated arch list (default: arm64,amd64)
  --keep-source              Keep temporary cloned source (if auto-cloned)
  -h, --help                 Show this help

Examples:
  sh scripts/build_macos_libsingbox.sh
  sh scripts/build_macos_libsingbox.sh --project-root /path/to/flutter_app
  sh scripts/build_macos_libsingbox.sh --singbox-dir /path/to/sing-box
  sh scripts/build_macos_libsingbox.sh --macos-arches arm64
EOF
}

log() { printf '[libsingbox-macos] %s\n' "$*" >&2; }
err() { printf '[libsingbox-macos] ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || err "Missing required command: $cmd"
}

normalize_arch() {
  case "$1" in
    arm64|aarch64) printf 'arm64\n' ;;
    amd64|x86_64) printf 'amd64\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

resolve_latest_release_tag() {
  local tag
  tag="$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name // empty')" || true
  if [[ -n "$tag" && "$tag" != "null" ]]; then
    printf '%s\n' "$tag"
    return
  fi
  printf 'main\n'
}

normalize_version_value() {
  local raw="${1:-}"
  raw="${raw#v}"
  raw="${raw%%[[:space:]]*}"
  printf '%s\n' "$raw"
}

resolve_build_version() {
  local source_dir="$1"
  local ref_hint="$2"
  local version=""

  if [[ -f "$source_dir/cmd/internal/read_tag/main.go" ]]; then
    version="$(cd "$source_dir" && GO111MODULE=on go run ./cmd/internal/read_tag 2>/dev/null || true)"
  fi
  if [[ -z "$version" ]]; then
    version="$(cd "$source_dir" && git describe --tags --abbrev=0 2>/dev/null || true)"
  fi
  if [[ -z "$version" ]]; then
    version="$ref_hint"
  fi
  if [[ -z "$version" || "$version" == "main" || "$version" == "master" || "$version" == "latest" ]]; then
    version="0.0.0-dev"
  fi

  normalize_version_value "$version"
}

prepare_source_dir() {
  if [[ -n "$SINGBOX_DIR" ]]; then
    [[ -d "$SINGBOX_DIR" ]] || err "sing-box directory not found: $SINGBOX_DIR"
    [[ -f "$SINGBOX_DIR/go.mod" ]] || err "Invalid sing-box directory (missing go.mod): $SINGBOX_DIR"
    [[ -d "$SINGBOX_DIR/cmd/sing-box" ]] || err "Invalid sing-box directory (missing cmd/sing-box): $SINGBOX_DIR"
    printf '%s\n' "$SINGBOX_DIR"
    return
  fi

  TMP_DIR="$(mktemp -d)"
  local source_dir="$TMP_DIR/sing-box"
  local ref_to_use="$SINGBOX_REF"
  if [[ "$ref_to_use" == "latest" ]]; then
    ref_to_use="$(resolve_latest_release_tag)"
  fi

  log "Cloning sing-box ($ref_to_use) from $SINGBOX_REPO_URL ..."
  if ! git clone --depth 1 --branch "$ref_to_use" "$SINGBOX_REPO_URL" "$source_dir" >/dev/null 2>&1; then
    log "Branch/tag clone failed for ref '$ref_to_use'; trying default clone + checkout..."
    git clone --depth 1 "$SINGBOX_REPO_URL" "$source_dir" >/dev/null
    (
      cd "$source_dir"
      git fetch --depth 1 origin "$ref_to_use" >/dev/null 2>&1 || true
      git checkout "$ref_to_use" >/dev/null
    )
  fi
  SINGBOX_VERSION="$(resolve_build_version "$source_dir" "$ref_to_use")"
  printf '%s\n' "$source_dir"
}

build_arch_binary() {
  local source_dir="$1"
  local arch="$2"
  local out_path="$3"

  log "Building sing-box for darwin/$arch ..."
  (
    cd "$source_dir"
    GOOS=darwin GOARCH="$arch" CGO_ENABLED=0 \
      GOCACHE="$BUILD_TMP/gocache" \
      GOMODCACHE="$BUILD_TMP/gomodcache" \
      GOFLAGS="-modcacherw" \
      go build -trimpath \
        -tags "$SINGBOX_BUILD_TAGS" \
        -ldflags "-X github.com/sagernet/sing-box/constant.Version=$SINGBOX_VERSION -X internal/godebug.defaultGODEBUG=multipathtcp=0 -s -w -buildid= -checklinkname=0" \
        -o "$out_path" ./cmd/sing-box
  )
}

cleanup() {
  if [[ -n "${BUILD_TMP:-}" && -d "${BUILD_TMP:-}" ]]; then
    chmod -R u+w "${BUILD_TMP:-}" >/dev/null 2>&1 || true
    rm -rf "${BUILD_TMP:-}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" && "${KEEP_SOURCE:-false}" != "true" ]]; then
    chmod -R u+w "${TMP_DIR:-}" >/dev/null 2>&1 || true
    rm -rf "${TMP_DIR:-}" >/dev/null 2>&1 || true
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)
      [[ $# -ge 2 ]] || err "Missing value for --project-root"
      PROJECT_ROOT="$(cd "$2" && pwd)"
      shift 2
      ;;
    --singbox-dir)
      [[ $# -ge 2 ]] || err "Missing value for --singbox-dir"
      SINGBOX_DIR="$(cd "$2" && pwd)"
      shift 2
      ;;
    --singbox-ref)
      [[ $# -ge 2 ]] || err "Missing value for --singbox-ref"
      SINGBOX_REF="$2"
      shift 2
      ;;
    --singbox-repo)
      [[ $# -ge 2 ]] || err "Missing value for --singbox-repo"
      SINGBOX_REPO_URL="$2"
      shift 2
      ;;
    --macos-arches)
      [[ $# -ge 2 ]] || err "Missing value for --macos-arches"
      MACOS_ARCHES="${2// /}"
      shift 2
      ;;
    --keep-source)
      KEEP_SOURCE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown option: $1"
      ;;
  esac
done

trap cleanup EXIT

require_cmd git
require_cmd go
require_cmd curl
require_cmd jq
require_cmd lipo

[[ -f "$PROJECT_ROOT/pubspec.yaml" ]] || err "pubspec.yaml not found at project root: $PROJECT_ROOT"
[[ -n "$MACOS_ARCHES" ]] || err "--macos-arches cannot be empty"

SOURCE_DIR="$(prepare_source_dir)"
OUT_DIR="$PROJECT_ROOT/macos/Frameworks"
OUT_PATH="$OUT_DIR/sing-box"
mkdir -p "$OUT_DIR"

BUILD_TMP="$(mktemp -d)"

IFS=',' read -r -a RAW_ARCHES <<< "$MACOS_ARCHES"
ARCHES=()
for raw_arch in "${RAW_ARCHES[@]}"; do
  [[ -n "$raw_arch" ]] || continue
  arch="$(normalize_arch "$raw_arch")"
  [[ "$arch" == "arm64" || "$arch" == "amd64" ]] || err "Unsupported macOS arch: $raw_arch (allowed: arm64,amd64)"
  ARCHES+=("$arch")
done
[[ ${#ARCHES[@]} -gt 0 ]] || err "No valid arch in --macos-arches"

BIN_PATHS=()
for arch in "${ARCHES[@]}"; do
  bin_path="$BUILD_TMP/sing-box-$arch"
  build_arch_binary "$SOURCE_DIR" "$arch" "$bin_path"
  BIN_PATHS+=("$bin_path")
done

if [[ ${#BIN_PATHS[@]} -eq 1 ]]; then
  rm -f "$OUT_PATH"
  cp "${BIN_PATHS[0]}" "$OUT_PATH"
else
  rm -f "$OUT_PATH"
  lipo -create "${BIN_PATHS[@]}" -output "$OUT_PATH"
fi

chmod +x "$OUT_PATH"

log "Saved: ${OUT_PATH#$PROJECT_ROOT/}"
log "Embedded version: $SINGBOX_VERSION"
log "Build tags: $SINGBOX_BUILD_TAGS"
log "Done."
