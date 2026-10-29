#!/usr/bin/env bash
# test/microbench/run_demo.sh -- open a demo ROM in RetroArch.
#
# The microbenchmark ROMs in this directory are headless by design (they
# exist to measure ticks, not to be watched), but the two "demo" ROMs are
# meant to be seen:
#
#   benchdemo_vidprobe.j64   a full-screen gradient, the smallest possible
#                            proof that the Object Processor path works
#   benchdemo_particles.j64  the particle explosion (256 particles, each
#                            with its own colour, on a 320x240 screen)
#
# This script puts the freshly built core into RetroArch's cores directory
# and launches RetroArch with the ROM loaded, so you can watch it.
#
# Usage:
#   test/microbench/run_demo.sh                 # the particle demo
#   test/microbench/run_demo.sh vidprobe        # the gradient probe
#   test/microbench/run_demo.sh --frames 300    # extra RetroArch flags
#
# Requires RetroArch (flatpak).  If it is not installed the script prints
# the one-line install command and exits.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

which_demo=particles
extra_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        vidprobe|particles) which_demo="$1"; shift ;;
        --) shift; extra_args=("$@"); break ;;
        *) extra_args+=("$1"); shift ;;
    esac
done

case "$which_demo" in
    vidprobe) rom="$here/benchdemo_vidprobe.j64" ;;
    *)       rom="$here/benchdemo_particles.j64" ;;
esac

core="$root/virtualjaguar_libretro.so"
if [ ! -f "$core" ]; then
    echo "error: $core not found -- build it first: make -j\$(nproc)" >&2
    exit 2
fi
if [ ! -f "$rom" ]; then
    echo "error: $rom not found -- build it: test/microbench/build.sh" >&2
    exit 2
fi

# RetroArch: flatpak if installed, otherwise a native binary on PATH.
if command -v flatpak >/dev/null 2>&1 && \
   flatpak --user list --columns=application 2>/dev/null | grep -q '^org\.libretro\.RetroArch$'; then
    ra_cores="$HOME/.var/app/org.libretro.RetroArch/config/retroarch/cores"
    mkdir -p "$ra_cores"
    cp -f "$core" "$ra_cores/virtualjaguar_libretro.so"
    echo "==> RetroArch (flatpak), core installed into $ra_cores"
    exec flatpak run org.libretro.RetroArch \
        -L "$ra_cores/virtualjaguar_libretro.so" \
        "${extra_args[@]+"${extra_args[@]}"}" "$rom"
elif command -v retroarch >/dev/null 2>&1; then
    cores_dir="${RETROARCH_CORES_DIR:-$HOME/.config/retroarch/cores}"
    mkdir -p "$cores_dir"
    cp -f "$core" "$cores_dir/virtualjaguar_libretro.so"
    echo "==> RetroArch (native), core installed into $cores_dir"
    exec retroarch -L "$cores_dir/virtualjaguar_libretro.so" \
        "${extra_args[@]+"${extra_args[@]}"}" "$rom"
else
    cat >&2 <<EOF
error: RetroArch is not installed.

  flatpak install --user flathub org.libretro.RetroArch

(or install a native RetroArch and make sure "retroarch" is on PATH).
EOF
    exit 2
fi
