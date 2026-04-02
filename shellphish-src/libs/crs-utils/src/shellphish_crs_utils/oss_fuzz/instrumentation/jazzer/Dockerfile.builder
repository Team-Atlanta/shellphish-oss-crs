# OSS-CRS: map target_base_image to BASE_IMAGE, default PREBUILD_IMAGE
ARG target_base_image
ARG BASE_IMAGE=${target_base_image}
ARG PREBUILD_IMAGE=crs-jazzer-prebuild:latest

# pull the prebuild image in with a given name
FROM ${PREBUILD_IMAGE} AS prebuild
FROM ${BASE_IMAGE} as jazzer_base_build


RUN mkdir -p /shellphish

# For Jazzer in out
COPY shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/jazzer/wrapper.py /shellphish/wrapper.py
RUN chmod +x /shellphish/wrapper.py

# [OSS-CRS glue] symlink_patch is handled by compile_shellphish_jazzer instead of
# appending to /usr/local/bin/compile (OSS-CRS doesn't use the oss-fuzz compile flow)
COPY shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/jazzer/symlink_patch /shellphish/symlink_patch

# Copy jazzer from prebuild
RUN mkdir -p $SRC/shellphish/jazzer-aixcc/jazzer-build/
RUN mkdir -p $OUT/shellphish/jazzer-aixcc/jazzer-build/

COPY --from=prebuild $SRC/shellphish/jazzer-aixcc/jazzer-build/jazzer_driver $SRC/shellphish/jazzer-aixcc/jazzer-build/jazzer_driver
COPY --from=prebuild $SRC/shellphish/jazzer-aixcc/jazzer-build/jazzer_agent_deploy.jar $SRC/shellphish/jazzer-aixcc/jazzer-build/jazzer_agent_deploy.jar

# Copy nautilus from prebuild
RUN mkdir -p $SRC/shellphish/nautilus
COPY --from=prebuild $SRC/shellphish/nautilus/librevolver_mutator.so $SRC/shellphish/nautilus
COPY --from=prebuild $SRC/shellphish/nautilus/watchtower $SRC/shellphish/nautilus

# --- OSS-CRS glue ---
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh
COPY bin/shellphish_build_helpers.sh /usr/local/bin/shellphish_build_helpers.sh
COPY bin/compile_shellphish_jazzer /usr/local/bin/compile_shellphish_jazzer
COPY bin/compile_canonical_build_java /usr/local/bin/compile_canonical_build_java
COPY bin/compile_jazzer_dispatch /usr/local/bin/compile_jazzer_dispatch
RUN chmod +x /usr/local/bin/shellphish_build_helpers.sh /usr/local/bin/compile_shellphish_jazzer /usr/local/bin/compile_canonical_build_java /usr/local/bin/compile_jazzer_dispatch
CMD ["compile_jazzer_dispatch"]
