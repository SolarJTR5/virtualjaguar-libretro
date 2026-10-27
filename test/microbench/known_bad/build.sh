#!/usr/bin/env bash
#
# test/microbench/known_bad/build.sh -- rebuild the KNOWN-BAD particle
# ROM used as the regression control for the harness's data check.
#
# It reuses the current 68K bootstrap (particle_boot.inc) with the old
# buggy RISC payload swapped in, so the only difference from the good
# ROM is the payload itself.
#
# Usage:  test/microbench/known_bad/build.sh [output.j64]
#         (default /tmp/benchgpu_particle_buggy.j64)

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mb="$(cd "$here/.." && pwd)"
out="${1:-/tmp/benchgpu_particle_buggy.j64}"

for tool in lyxass rmac rln; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: $tool not on PATH -- run from the repo root:" >&2
        echo "  eval \"\$(tools/jaguar-toolchain/setup.sh env)\"" >&2
        exit 1
    }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cd "$mb"

lyxass -o "$tmp/buggy.o" "$here/benchgpu_particle_persp2_buggy.s"
tail -c +13 "$tmp/buggy.o" > "$tmp/buggy.bin"     # strip the 12-byte BS94 header

# Same bootstrap, but carry the buggy blob instead of the selected one.
sed "s|        .if     VARIANT = 1|        .if     1|; \
     s|        .incbin \"benchgpu_particle_gpu.bin\"|        .incbin \"$tmp/buggy.bin\"|" \
    particle_boot.inc > "$tmp/boot.inc"

cat > "$tmp/main.s" <<EOF
VARIANT .equ    1
        .include "$tmp/boot.inc"
EOF

rmac -fb -o "$tmp/main.o" "$tmp/main.s" >/dev/null
rln -n -a 800000 x x -o "$out" "$tmp/main.o" >/dev/null

echo "built $out"
