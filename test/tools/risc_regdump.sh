#!/usr/bin/env bash
# risc_regdump.sh -- print the GPU or DSP register file as a hex grid.
#
# Runs an existing microbench harness under host gdb, stops at a harness
# symbol, and reads the RISC register file through the test-only exports
# GPUGetReg/GPUGetPC/GPUGetFlags/GPUGetControl (or the DSP equivalents).
# The core must be built with TEST_EXPORTS=1, which is the same build the
# microbench suite already uses.
#
# This is a developer/observation tool, not part of `make test`: it needs
# gdb, which the devbox image does not ship.  Run it on the host against
# a tree already built inside the devbox.
#
# Usage:
#   test/tools/risc_regdump.sh [--gpu|--dsp] [--rom ROM] [--map particle]
#                              [--at SYMBOL] [--harness PATH] [--core PATH]
#                              [--raw] [-- harness args...]
#
# Examples:
#   test/tools/risc_regdump.sh
#   test/tools/risc_regdump.sh --map particle
#   test/tools/risc_regdump.sh --dsp --rom test/microbench/benchdsp_mix.j64
#   test/tools/risc_regdump.sh --rom path/to/demo.j64 --frames 60
#
# The default stop point is harness_shutdown(), i.e. the state the ROM
# left the unit in when it halted.  For live values inside a loop, point
# --at at a harness symbol that runs while the unit is active.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

unit=gpu
rom=""
rom_set=0
core="./virtualjaguar_libretro.so"
harness=""
at="harness_shutdown"
annotate=""
raw=0
extra=()

usage() {
    cat <<'EOF'
Usage: test/tools/risc_regdump.sh [options] [-- harness args...]

  --gpu              dump GPU registers (default)
  --dsp              dump DSP registers
  --rom PATH         ROM to run (default: the particle ROM, or benchdsp_mix
                     with --dsp)
  --harness PATH     harness binary (default: test_microbench_gpu_particle,
                     or test_microbench_dsp_mix with --dsp)
  --core PATH        core .so (default: ./virtualjaguar_libretro.so)
  --at SYMBOL        harness symbol to stop at (default: harness_shutdown)
  --map particle     annotate the particle payload's register roles
  --raw              also show the unfiltered gdb output
  -h, --help         this text

Needs a TEST_EXPORTS=1 build and host gdb.  Arguments after -- are passed
to the harness (e.g. --frames 60).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --gpu) unit=gpu; shift ;;
        --dsp) unit=dsp; shift ;;
        --rom) rom="${2:?--rom needs a path}"; rom_set=1; shift 2 ;;
        --core) core="${2:?--core needs a path}"; shift 2 ;;
        --harness) harness="${2:?--harness needs a path}"; shift 2 ;;
        --at) at="${2:?--at needs a symbol}"; shift 2 ;;
        --map) annotate="${2:?--map needs a name}"; shift 2 ;;
        --raw) raw=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; extra=("$@"); break ;;
        -*) echo "risc_regdump: unknown option '$1' (use -- before harness flags)" >&2; exit 2 ;;
        *) extra+=("$1"); shift ;;
    esac
done

if [ "$unit" = dsp ]; then
    prefix=DSP
    [ -n "$harness" ] || harness="./test/tools/test_microbench_dsp_mix"
    if [ "$rom_set" -eq 0 ]; then
        rom="test/microbench/benchdsp_mix.j64"
    fi
else
    prefix=GPU
    [ -n "$harness" ] || harness="./test/tools/test_microbench_gpu_particle"
    if [ "$rom_set" -eq 0 ]; then
        rom="test/microbench/benchgpu_particle.j64"
    fi
fi

command -v gdb >/dev/null 2>&1 || {
    echo "risc_regdump: gdb not found (the devbox has no gdb; run this on the host)" >&2
    exit 2
}
for f in "$core" "$harness" "$rom"; do
    [ -e "$f" ] || { echo "risc_regdump: missing $f" >&2; exit 2; }
done
exports="$(nm -D "$core" 2>/dev/null || true)"
case "$exports" in
    *" ${prefix}GetReg"*) ;;
    *)
        echo "risc_regdump: $core does not export ${prefix}GetReg" >&2
        echo "               rebuild with: make TEST_EXPORTS=1 test/tools/$(basename "$harness")" >&2
        exit 2
        ;;
esac

core_dir="$(cd "$(dirname "$core")" && pwd)"
core_abs="$core_dir/$(basename "$core")"

gdb_script="$(mktemp)"
trap 'rm -f "$gdb_script"' EXIT

{
    echo 'set confirm off'
    echo 'set pagination off'
    echo 'set debuginfod enabled off'
    echo 'set breakpoint pending on'
    echo "file $harness"
    echo "set env LD_LIBRARY_PATH=$core_dir:."
    echo "break $at"
    printf 'run "%s" "%s"' "$core_abs" "$rom"
    for a in "${extra[@]}"; do
        printf ' "%s"' "$a"
    done
    printf '\n'
    printf 'printf "%s  PC=$%%06X  FLAGS=$%%08X  CTRL=$%%08X\\n", ((unsigned int(*)(void))%sGetPC)(), ((unsigned int(*)(void))%sGetFlags)(), ((unsigned int(*)(void))%sGetControl)()\n' "$prefix" "$prefix" "$prefix" "$prefix"
    echo 'set $i=0'
    echo 'while $i<32'
    printf '  printf "r%%-2d=$%%08X%%s", $i, ((unsigned int(*)(int))%sGetReg)($i), ($i%%4==3) ? "\\n" : "  "\n' "$prefix"
    echo '  set $i=$i+1'
    echo 'end'
    echo 'quit'
} > "$gdb_script"

set +e
out="$(gdb -q -batch -x "$gdb_script" 2>&1)"
status=$?
set -e

if [ "$raw" -eq 1 ]; then
    printf '%s\n' "$out"
fi

dump="$(printf '%s\n' "$out" | grep -E "^(${prefix}  PC=|r[0-9])" || true)"
if [ -z "$dump" ]; then
    echo "risc_regdump: gdb produced no ${prefix} register dump (exit $status)" >&2
    [ "$raw" -eq 1 ] || printf '%s\n' "$out" | tail -20 >&2
    exit 1
fi
printf '%s\n' "$dump"

if [ "$annotate" = particle ]; then
    cat <<'EOF'

roles in the particle payload:
  r14  input cursor        r15  output cursor ($00030000 base)
  r17  particle count      r20,r21  DIV/MULT lane results (scratch)
EOF
elif [ "$annotate" = interleave ]; then
    cat <<'EOF'

roles in the interleave payloads:
  r1   loop bound          r18  address-biased constant
  r20  DIV result          r21  MULT result
EOF
fi
