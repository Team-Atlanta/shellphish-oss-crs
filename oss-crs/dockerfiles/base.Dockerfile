# Build AFL++ from source on the standard OSS-Fuzz base-clang image.
# Using base-clang ensures the compiled AFL++ LLVM passes are compatible
# with target_base_image (which inherits from the same base-clang lineage).
#
# The result is /opt/aflpp/ containing all AFL++ binaries, libraries, and
# support files needed for both compilation (afl-clang-fast) and fuzzing (afl-fuzz).

FROM gcr.io/oss-fuzz-base/base-clang AS aflpp-build

RUN apt-get update && apt-get install -y \
    gcc g++ build-essential python3-dev automake cmake git flex bison \
    libglib2.0-dev libpixman-1-dev python3-setuptools cargo \
    gcc-9-plugin-dev libstdc++-9-dev ninja-build patchelf \
    && rm -rf /var/lib/apt/lists/*

RUN git clone -b v4.30c https://github.com/AFLplusplus/AFLplusplus /afl

RUN cd /afl && \
    unset CFLAGS CXXFLAGS && \
    export CC=clang CXX=clang++ && \
    export REAL_CC=gcc REAL_CXX=g++ && \
    export AFL_NO_X86=1 NO_NYX=1 && \
    sed -i 's/-Wno-deprecated-copy-with-dtor//g' ./GNUmakefile.llvm && \
    LLVM_CONFIG=$(which llvm-config) STATIC=1 PYTHON_INCLUDE=/ make source-only && \
    make -C utils/aflpp_driver

# Collect all AFL++ artifacts into /opt/aflpp/
RUN mkdir -p /opt/aflpp && \
    cd /afl && \
    cp afl-fuzz afl-clang-fast afl-clang-fast++ afl-showmap afl-tmin afl-cmin \
       afl-compiler-rt.o afl-compiler-rt-32.o afl-compiler-rt-64.o \
       afl-llvm-pass.so afl-llvm-lto-instrumentlist.so \
       dynamic_list.txt \
       /opt/aflpp/ 2>/dev/null; \
    cp *.a *.o *.so /opt/aflpp/ 2>/dev/null; \
    cp utils/aflpp_driver/libAFLDriver.a /opt/aflpp/ ; \
    cp -r /afl/include /opt/aflpp/include 2>/dev/null; true

# Final minimal image holding just the pre-compiled artifacts
FROM scratch
COPY --from=aflpp-build /opt/aflpp /opt/aflpp
