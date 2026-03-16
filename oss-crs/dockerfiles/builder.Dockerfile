# Target builder: instruments the OSS-Fuzz target with AFL++ (afl-clang-fast).
#
# Multi-stage:
#   1. Pull pre-compiled AFL++ from the prepare-phase base image
#   2. FROM target_base_image (has target source + clang toolchain)
#   3. Copy AFL++ tools into $SRC/shellphish/aflplusplus/ (Shellphish convention)
#   4. Run compile_target which sets up AFL++ env, calls `compile`, and submits output

FROM crs-aflpp-base:latest AS aflpp

ARG target_base_image
FROM ${target_base_image}

# Install libCRS
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh

# Place pre-compiled AFL++ where compile_target expects it
RUN mkdir -p $SRC/shellphish/aflplusplus
COPY --from=aflpp /opt/aflpp/ $SRC/shellphish/aflplusplus/

# Install build dependencies that AFL++ instrumentation may need
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc-9-plugin-dev libstdc++-9-dev patchelf \
    && rm -rf /var/lib/apt/lists/*

COPY bin/compile_target /usr/local/bin/compile_target
RUN chmod +x /usr/local/bin/compile_target

CMD ["compile_target"]
