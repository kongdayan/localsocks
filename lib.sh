#!/usr/bin/env bash
# Shared helpers for the localsocks scripts. Source, do not execute directly.

HYS2_VERSION="${HY_VERSION:-v2.6.0}"

hys2_arch() {
  case "$(uname -m)" in
    arm64|aarch64) echo "arm64" ;;
    x86_64|amd64)  echo "amd64" ;;
    *) echo "unsupported-arch" ;;
  esac
}

# ensure_binary <dest-path> -> downloads the hysteria release binary if missing
ensure_binary() {
  local dest="$1"
  [ -x "$dest" ] && return 0

  local arch; arch="$(hys2_arch)"
  if [ "$arch" = "unsupported-arch" ]; then
    echo "unsupported architecture: $(uname -m)" >&2
    return 1
  fi

  local url="https://github.com/apernet/hysteria/releases/download/app%2F${HYS2_VERSION}/hysteria-darwin-${arch}"
  echo "fetching hysteria ${HYS2_VERSION} (darwin-${arch})" >&2
  mkdir -p "$(dirname "$dest")"
  if ! curl -fL --retry 3 --connect-timeout 15 -o "$dest.part" "$url"; then
    rm -f "$dest.part"
    echo "download failed: $url" >&2
    return 1
  fi
  chmod +x "$dest.part"
  mv "$dest.part" "$dest"
}

# log <file> <message...> -> timestamped line to file (and stdout)
hys2log() {
  local file="$1"; shift
  local line
  line="$(date '+%Y-%m-%dT%H:%M:%S%z') [$$] $*"
  printf '%s\n' "$line"
  [ -n "$file" ] && printf '%s\n' "$line" >>"$file" 2>/dev/null || true
}

# rotate <file> <max-bytes> -> truncates to the last half when oversized
rotate_file() {
  local file="$1" max="${2:-5242880}"
  [ -f "$file" ] || return 0
  local size; size="$(wc -c <"$file" 2>/dev/null || echo 0)"
  [ "$size" -le "$max" ] && return 0
  tail -c $((max / 2)) "$file" >"$file.tmp" 2>/dev/null && mv "$file.tmp" "$file"
}
