#!/usr/bin/env bash
# test/microbench/run_demo.sh -- watch or listen to the demo ROMs.
#
# The microbenchmark ROMs in this directory are headless by design (they
# exist to measure ticks, not to be watched), but the "demo" ROMs are
# meant to be seen and heard:
#
#   particles   the particle explosion: 64 particles, each with its own
#               hue, bouncing around a 320x240 framebuffer that the
#               Object Processor scans out every field
#   vidprobe    a full-screen gradient, the smallest possible proof that
#               the Object Processor path works
#   audio       the 68K-only I2S square wave (about 2.75 kHz, stereo);
#               there is no video, so the screen stays black
#
# Usage:
#   test/microbench/run_demo.sh                  # particles, in RetroArch
#   test/microbench/run_demo.sh vidprobe         # the gradient probe
#   test/microbench/run_demo.sh audio            # listen in RetroArch
#   test/microbench/run_demo.sh audio --wav      # render a WAV and play it
#   test/microbench/run_demo.sh audio --wav out.wav
#   test/microbench/run_demo.sh bigpemu audio    # a second, independent
#                                                # emulator as an oracle
#   test/microbench/run_demo.sh particles -- -f  # extra emulator flags
#
# `--wav` needs no emulator at all: it runs the core headless, captures
# the audio it produces and writes a plain 48 kHz stereo WAV file.  That
# is the most reliable way to hear the demo on a box where RetroArch is
# awkward to find, and it is also what an audio regression can be
# diffed against.
#
# bigPEmu mode runs the ROM in the flathub build of BigPEmu instead, which
# is useful as an independent check: if the two emulators disagree, the
# ROM (or one of the emulators) has a real bug, and the picture tells you
# which.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

which_demo=particles
mode=retroarch
wav_path=""
extra_args=()

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        particles|vidprobe|audio) which_demo="$1"; shift ;;
        bigpemu) mode=bigpemu; shift ;;
        --wav)
            mode=wav
            if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then
                wav_path="$2"; shift
            fi
            shift ;;
        --) shift; extra_args=("$@"); break ;;
        *) extra_args+=("$1"); shift ;;
    esac
done

case "$which_demo" in
    vidprobe) rom="$here/benchdemo_vidprobe.j64" ;;
    audio)    rom="$here/benchdemo_audio.j64" ;;
    *)        rom="$here/benchdemo_particles.j64" ;;
esac

core="$root/virtualjaguar_libretro.so"

# ---------------------------------------------------------------- WAV mode
# Headless: build the capture tool if it is missing, run the ROM through
# the core, and write what the core's audio callback produced.
if [ "$mode" = wav ]; then
    tool="$root/test/tools/test_demo_audio"
    if [ ! -x "$tool" ] || [ ! -f "$core" ]; then
        echo "==> building the core and the audio tool" >&2
        ( cd "$root" && make TEST_EXPORTS=1 -j"$(nproc)" \
              test/tools/test_demo_audio >/dev/null )
    fi
    if [ -z "$wav_path" ]; then
        wav_path="${TMPDIR:-/tmp}/jaguar_audio_demo.wav"
    fi
    echo "==> capturing $which_demo audio into $wav_path"
    "$tool" "$core" "$rom" --frames 240 --wav "$wav_path"
    echo
    if command -v xdg-open >/dev/null 2>&1 && [ -z "${VJ_NO_PLAY:-}" ]; then
        echo "==> playing it"
        xdg-open "$wav_path" >/dev/null 2>&1 || true
    else
        echo "play it with:  aplay '$wav_path'   (or any audio player)"
    fi
    exit 0
fi

# ------------------------------------------------------------ bigPEmu mode
if [ "$mode" = bigpemu ]; then
    if ! command -v flatpak >/dev/null 2>&1 || \
       ! flatpak --user list --columns=application 2>/dev/null \
           | grep -q '^com\.richwhitehouse\.BigPEmu$'; then
        cat >&2 <<EOF
error: BigPEmu is not installed.

  flatpak install --user flathub com.richwhitehouse.BigPEmu

BigPEmu needs a Jaguar BIOS image.  It looks for one next to the ROM and
in its own user-data directory; point it at one in the GUI once and it
remembers.  (A retail BIOS runs the cart's universal marker: our ROMs
carry the same \$04040404 marker and entry vector as yarc.j64, so they
boot there too.)
EOF
        exit 2
    fi
    echo "==> BigPEmu: $rom"
    exec flatpak run com.richwhitehouse.BigPEmu "$rom" \
        "${extra_args[@]+"${extra_args[@]}"}"
fi

# ------------------------------------------------------------ RetroArch mode
if [ ! -f "$core" ]; then
    echo "error: $core not found -- build it first: make -j\$(nproc)" >&2
    exit 2
fi
if [ ! -f "$rom" ]; then
    echo "error: $rom not found -- build it: test/microbench/build.sh" >&2
    exit 2
fi

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
Use "--wav" for the audio demo if you would rather not install anything.
EOF
    exit 2
fi
