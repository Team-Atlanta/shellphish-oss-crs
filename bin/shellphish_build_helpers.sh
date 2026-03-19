#!/bin/bash
# OSS-CRS glue: shared build helpers replicating get_build_command() logic
# from project.py:1016-1049. All build steps source this file.

# --- ccache configuration (project.py:1018-1032) ---
setup_ccache() {
    if [[ "${ARTIPHISHELL_CCACHE_DISABLE:-0}" != "1" ]] && [ -d /ccache ]; then
        ln -sf /usr/local/bin/ccache /ccache/bin/gcc 2>/dev/null || true
        ln -sf /usr/local/bin/ccache /ccache/bin/g++ 2>/dev/null || true
        export CCACHE_DIR="/shared/ccache"
        export CCACHE_MAXSIZE="100G"
        export CMAKE_C_COMPILER_LAUNCHER=ccache
        export CMAKE_CXX_COMPILER_LAUNCHER=ccache
        export PATH="/ccache/bin:$PATH"
    fi
    echo "Compiling with $(command -v ${CC:-cc} 2>/dev/null || echo ${CC:-cc})"
}

# --- post_build_commands (project.py:1009-1014) ---
# Extract harness entry point addresses/symbols, copy llvm tools to $OUT.
run_post_build_commands() {
    local out_dir="${1:-$OUT}"
    # Harness address extraction
    find "$out_dir" -type f -maxdepth 1 -exec sh -c '
        if readelf -h "$1" 2>/dev/null | grep -q "ELF Header:" && grep -q LLVMFuzzerTestOneInput "$1" 2>/dev/null; then
            echo "Processing: $1"
            harness_address=$(llvm-nm "$1" 2>/dev/null | grep LLVMFuzzerTestOneInput | awk "{print \"0x\"\$1}")
            echo "$harness_address" > "$1.shellphish_harness_address.txt"
            llvm-symbolizer --obj="$1" --output-style=JSON "$harness_address" > "$1.shellphish_harness_symbols.json" 2>/dev/null
        fi
    ' _ {} \; 2>/dev/null || true
    # Copy llvm tools
    for bin in llvm-nm llvm-cov llvm-objcopy; do
        cp "$(which $bin 2>/dev/null)" "$out_dir/" 2>/dev/null || true
    done
}
