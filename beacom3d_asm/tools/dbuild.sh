#!/bin/bash
# Build and test inside a container, from any host (Git Bash on Windows,
# Linux, macOS) with Docker or Podman.
#
#   tools/dbuild.sh linux    Linux build -> ./beacom3d
#   tools/dbuild.sh test     Linux build + headless --selftest (physics, AI, nav checks)
#   tools/dbuild.sh shots    Linux build + headless --shot screenshots into shots/
#   tools/dbuild.sh win      Windows cross-build -> beacom3d.exe + SDL DLLs
#
# The build images are made from Dockerfile / Dockerfile.windows the first
# time they're needed. Overrides: ENGINE=docker|podman, LINUX_IMG=..., WIN_IMG=...
cd "$(dirname "$0")/.." || exit 1
if command -v cygpath >/dev/null; then ROOT="$(cygpath -w "$(pwd)/..")"; else ROOT="$(cd .. && pwd)"; fi
LINUX_IMG="${LINUX_IMG:-beacom3d}"
WIN_IMG="${WIN_IMG:-beacom3d-win}"
if [ -z "$ENGINE" ]; then
  if command -v docker >/dev/null; then ENGINE=docker
  elif command -v podman >/dev/null; then ENGINE=podman
  else echo "dbuild: needs docker or podman" >&2; exit 1; fi
fi
# Podman (also when installed as "docker"): relabel the mount for SELinux hosts
VOL_OPT=""
if "$ENGINE" --version 2>/dev/null | grep -qi podman; then VOL_OPT=":Z"; fi
export MSYS_NO_PATHCONV=1
quiet='grep -v "^nasm \|^gcc \|^x86_64-w64"'

# ensure_image IMAGE DOCKERFILE -- build it from the repository root if missing
ensure_image() {
  if ! "$ENGINE" image inspect "$1" >/dev/null 2>&1; then
    echo "dbuild: image '$1' not found -- building it from beacom3d_asm/$2 (first time only)..."
    local df="$(pwd)/$2"
    if command -v cygpath >/dev/null; then df="$(cygpath -w "$df")"; fi
    "$ENGINE" build -t "$1" -f "$df" "$ROOT" || exit 1
  fi
}
run_in() { "$ENGINE" run --rm -v "$ROOT:/game$VOL_OPT" -w /game/beacom3d_asm "$1" bash -c "$2"; }
linux() { ensure_image "$LINUX_IMG" Dockerfile; run_in "$LINUX_IMG" "$1"; }

case "${1:-linux}" in
  linux) linux "make 2>&1 | $quiet; test -x beacom3d" ;;
  test)  linux "make 2>&1 | $quiet; test -x beacom3d && SDL_AUDIODRIVER=dummy timeout 600 xvfb-run -a -s '-screen 0 640x360x24' stdbuf -oL ./beacom3d --selftest" ;;
  shots) linux "make 2>&1 | $quiet; test -x beacom3d && SDL_AUDIODRIVER=dummy timeout 600 xvfb-run -a -s '-screen 0 1280x720x24' ./beacom3d --shot" ;;
  win)   ensure_image "$WIN_IMG" Dockerfile.windows
         run_in "$WIN_IMG" "make windows 2>&1 | $quiet; test -f beacom3d.exe" ;;
  *) echo "usage: $0 linux|test|shots|win"; exit 2 ;;
esac
