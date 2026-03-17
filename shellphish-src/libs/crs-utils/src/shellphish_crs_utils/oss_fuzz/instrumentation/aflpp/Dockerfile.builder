# OSS-CRS passes target_base_image; map to BASE_IMAGE for compatibility
ARG target_base_image
ARG BASE_IMAGE=${target_base_image}
ARG PREBUILD_IMAGE=crs-aflpp-prebuild:latest

# pull the prebuild image in with a given name
FROM ${PREBUILD_IMAGE} AS prebuild

FROM ${BASE_IMAGE} AS final-builder

RUN echo 1
RUN apt-get update && apt-get install -y gcc g++
RUN apt-get update && \
    apt-get install -y \
    build-essential \
    gcc-9-plugin-dev \
    libstdc++-9-dev \
    patchelf

RUN mv /usr/bin/ld /usr/bin/ld.real
COPY shellphish-src/libs/c-instrumentation/anti-wrap-ld.sh /usr/bin/ld
RUN chmod +x /usr/bin/ld

RUN mkdir -p $SRC/shellphish
COPY --from=prebuild  $SRC/shellphish/aflplusplus $SRC/shellphish/aflplusplus
# COPY aflpp_patch/dewrap* $SRC/shellphish/aflplusplus/instrumentation/
# RUN ls -al /afl && cd /afl && git apply $SRC/shellphish/aflplusplus/instrumentation/dewrap_patch.diff
RUN cat $SRC/shellphish/aflplusplus/src/afl-fuzz-run.c | grep "SHELLPHISH"

RUN mkdir -p $SRC/shellphish/nautilus
COPY --from=prebuild $SRC/nautilus/target/release/librevolver_mutator.so $SRC/shellphish/nautilus
COPY --from=prebuild $SRC/nautilus/target/release/watchtower $SRC/shellphish/nautilus
COPY --from=prebuild $SRC/nautilus/target/release/generator $SRC/shellphish/nautilus

COPY shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/aflpp/compile_shellphish_aflpp /usr/local/bin/

# --- OSS-CRS glue ---
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh
COPY bin/compile_target /usr/local/bin/compile_target
RUN chmod +x /usr/local/bin/compile_target
CMD ["compile_target"]
