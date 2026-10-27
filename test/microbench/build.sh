#!/usr/bin/env bash
#
# test/microbench/build.sh -- regenerate the committed microbenchmark .j64
# images from their .s sources.
#
# CI never runs this: the .j64 files are committed so the test suite needs
# no assembler (issue #536's own requirement).  Run it only when you edit
# a .s source, then commit the regenerated .j64 alongside it.
#
# Requires the Jaguar toolchain:
#   make jaguar-toolchain-build
#   eval "$(tools/jaguar-toolchain/setup.sh env)"
#   test/microbench/build.sh
#
# rmac/rln output is byte-reproducible (verified: two builds of the same
# source cmp identical), so a regenerated .j64 diffs only when the source
# actually changed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

for tool in rmac rln; do
    command -v "${tool}" >/dev/null 2>&1 || {
        echo "error: ${tool} not on PATH -- run: eval \"\$(tools/jaguar-toolchain/setup.sh env)\"" >&2
        exit 1
    }
done

# GPU/DSP RISC blobs (tasks 2-5): a *_gpu.s or *_dsp.s source is the
# companion RISC program for a same-named 68K bootstrap (e.g.
# benchgpu_arith_gpu.s -> benchgpu_arith.s's `.incbin
# "benchgpu_arith_gpu.bin"`).  lyxass targets the GPU/DSP ISA, not the
# 68000, so it needs its own tool and its own pass, run BEFORE the 68K
# source that .incbin's the result.  lyxass output is a 12-byte BS94
# header (magic + run address + code length) followed by the raw code;
# a naive .incbin of the .o would feed that header to the RISC core as
# instructions, so strip it here -- see README.md "embedding a lyxass
# GPU/DSP blob".
# Shared GPU/DSP payloads (task 6): ONE source, assembled once per core
# AND once per slot.  The RISC has no relocatable code -- the local-RAM
# base and the control register are baked in at assembly time -- so each
# payload must be assembled for the address it will actually run at.
# The three slots are $F03000/$F03100/$F03200 (GPU) and
# $F1B000/$F1B100/$F1B200 (DSP).
#
# The slot comes from the payload's name: naive -> 0, shadow -> 1,
# deep -> 2.  (The DSP audio-mix payloads use the same rule: the mix's
# 1-deep payload is the "naive" one and its 2-deep one is the "deep"
# one, so they land in slots 0 and 2.)
for payload in benchinterleave_naive.s benchinterleave_shadow.s benchinterleave_deep.s benchdspmix_naive.s benchdspmix_deep.s; do
    command -v lyxass >/dev/null 2>&1 || {
        echo "error: lyxass not on PATH -- run: eval \"\$(tools/jaguar-toolchain/setup.sh env)\"" >&2
        exit 1
    }
    name="${payload%.s}"
    case "${name}" in
        *naive)  slot=0 ;;
        *shadow) slot=1 ;;
        *deep)   slot=2 ;;
        *) echo "error: unknown payload slot for ${name}" >&2; exit 1 ;;
    esac
    gpu_base=$(printf '$F0%04X' $(( 0x3000 + slot * 0x100 )))
    dsp_base=$(printf '$F1%04X' $(( 0xB000 + slot * 0x100 )))
    lyxass -D "BASE=${gpu_base}" -D 'CTRL=$00F02114' -o "${name}_gpu.o" "${payload}"
    tail -c +13 "${name}_gpu.o" > "${name}_gpu.bin"
    command rm -f "${name}_gpu.o"
    lyxass -D "BASE=${dsp_base}" -D 'CTRL=$00F1A114' -o "${name}_dsp.o" "${payload}"
    tail -c +13 "${name}_dsp.o" > "${name}_dsp.bin"
    command rm -f "${name}_dsp.o"
    echo "    ${name}: slot ${slot}, gpu ${gpu_base} ($(wc -c < "${name}_gpu.bin" | tr -d ' ') bytes), dsp ${dsp_base} ($(wc -c < "${name}_dsp.bin" | tr -d ' ') bytes)"
done

for risc_src in *_gpu.s *_dsp.s; do
    [ -f "${risc_src}" ] || continue
    command -v lyxass >/dev/null 2>&1 || {
        echo "error: lyxass not on PATH -- run: eval \"\$(tools/jaguar-toolchain/setup.sh env)\"" >&2
        exit 1
    }
    risc_base="${risc_src%.s}"
    echo "==> ${risc_base} (lyxass)"
    lyxass -o "${risc_base}.o" "${risc_src}"
    tail -c +13 "${risc_base}.o" > "${risc_base}.bin"
    command rm -f "${risc_base}.o"
    echo "    $(wc -c < "${risc_base}.bin" | tr -d ' ') bytes (header stripped)"
done

# 68K-only sources: header + code in one translation unit, linked flat at
# the cart base.  A source that .incbin's a *_gpu.bin/*_dsp.bin blob (just
# produced above) picks it up automatically -- rmac resolves .incbin
# relative to this directory since we already cd'd here.
for src in bench68k.s benchgpu_arith.s benchgpu_branch.s benchdsp.s benchblit.s benchgpu_interleave.s benchdsp_interleave.s benchdsp_mix.s benchgpu_particle.s benchgpu_particle_naive.s; do
    [ -f "${src}" ] || continue
    base="${src%.s}"
    echo "==> ${base}"
    rmac -fb -o "${base}.o" "${src}"
    rln -n -a 800000 x x -o "${base}.j64" "${base}.o" >/dev/null
    command rm -f "${base}.o"
    echo "    $(wc -c < "${base}.j64" | tr -d ' ') bytes"
done

# Intermediate RISC blobs are regenerated from source every run (same
# byte-reproducibility property as the .o files above) -- only the final
# .j64 is committed, so don't leave these lying around.
command rm -f -- *_gpu.bin *_dsp.bin
