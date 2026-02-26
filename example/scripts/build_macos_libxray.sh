#!/usr/bin/env bash
set -euo pipefail

XRAY_REPO_URL="https://github.com/XTLS/Xray-core.git"
XRAY_REF="latest"
PROJECT_ROOT="$(pwd)"
XRAY_CORE_DIR=""
KEEP_SOURCE=false
TMP_DIR=""
MACOS_ARCHES="arm64,amd64"
BUILD_TMP=""

usage() {
  cat <<'EOF'
Usage: build_macos_libxray.sh [options]

Build macOS xray binary from XTLS/Xray-core and place it in:
  macos/Frameworks/xray

Options:
  --project-root <path>      Flutter app root (default: current directory)
  --xray-core-dir <path>     Use an existing local Xray-core directory
  --xray-ref <ref|main|latest> Xray-core git ref to use when auto-cloning (default: latest release tag)
  --xray-repo <url>          Xray-core git repo URL (default: https://github.com/XTLS/Xray-core.git)
  --macos-arches <list>      Comma-separated arch list (default: arm64,amd64)
  --keep-source              Keep temporary cloned source (if auto-cloned)
  -h, --help                 Show this help

Examples:
  sh scripts/build_macos_libxray.sh
  sh scripts/build_macos_libxray.sh --project-root /path/to/flutter_app
  sh scripts/build_macos_libxray.sh --xray-core-dir /path/to/Xray-core
  sh scripts/build_macos_libxray.sh --macos-arches arm64
EOF
}

log() { printf '[libxray-macos] %s\n' "$*" >&2; }
err() { printf '[libxray-macos] ERROR: %s\n' "$*" >&2; exit 1; }

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
  tag="$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r '.tag_name // empty')" || true
  if [[ -n "$tag" && "$tag" != "null" ]]; then
    printf '%s\n' "$tag"
    return
  fi
  printf 'main\n'
}

prepare_source_dir() {
  if [[ -n "$XRAY_CORE_DIR" ]]; then
    [[ -d "$XRAY_CORE_DIR" ]] || err "Xray-core directory not found: $XRAY_CORE_DIR"
    [[ -f "$XRAY_CORE_DIR/go.mod" ]] || err "Invalid Xray-core directory (missing go.mod): $XRAY_CORE_DIR"
    [[ -d "$XRAY_CORE_DIR/main" ]] || err "Invalid Xray-core directory (missing main/): $XRAY_CORE_DIR"
    printf '%s\n' "$XRAY_CORE_DIR"
    return
  fi

  TMP_DIR="$(mktemp -d)"
  local source_dir="$TMP_DIR/Xray-core"
  local ref_to_use="$XRAY_REF"
  if [[ "$ref_to_use" == "latest" ]]; then
    ref_to_use="$(resolve_latest_release_tag)"
  fi

  log "Cloning Xray-core ($ref_to_use) from $XRAY_REPO_URL ..."
  if ! git clone --depth 1 --branch "$ref_to_use" "$XRAY_REPO_URL" "$source_dir" >/dev/null 2>&1; then
    log "Branch/tag clone failed for ref '$ref_to_use'; trying default clone + checkout..."
    git clone --depth 1 "$XRAY_REPO_URL" "$source_dir" >/dev/null
    (
      cd "$source_dir"
      git fetch --depth 1 origin "$ref_to_use" >/dev/null 2>&1 || true
      git checkout "$ref_to_use" >/dev/null
    )
  fi
  printf '%s\n' "$source_dir"
}

build_arch_binary() {
  local source_dir="$1"
  local arch="$2"
  local out_path="$3"

  log "Building xray for darwin/$arch ..."
  (
    cd "$source_dir"
    GOOS=darwin GOARCH="$arch" CGO_ENABLED=0 \
      GOCACHE="$BUILD_TMP/gocache" \
      GOMODCACHE="$BUILD_TMP/gomodcache" \
      GOFLAGS="-modcacherw" \
      go build -trimpath -ldflags "-s -w -buildid=" -o "$out_path" ./main
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
    --xray-core-dir)
      [[ $# -ge 2 ]] || err "Missing value for --xray-core-dir"
      XRAY_CORE_DIR="$(cd "$2" && pwd)"
      shift 2
      ;;
    --xray-ref)
      [[ $# -ge 2 ]] || err "Missing value for --xray-ref"
      XRAY_REF="$2"
      shift 2
      ;;
    --xray-repo)
      [[ $# -ge 2 ]] || err "Missing value for --xray-repo"
      XRAY_REPO_URL="$2"
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
OUT_PATH="$OUT_DIR/xray"
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
  bin_path="$BUILD_TMP/xray-$arch"
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
log "Done."
