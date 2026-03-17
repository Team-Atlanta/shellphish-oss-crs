# OSS-CRS: map target_base_image to BASE_IMAGE, default PREBUILD_IMAGE
ARG target_base_image
ARG BASE_IMAGE=${target_base_image}
ARG PREBUILD_IMAGE=crs-libfuzzer-prebuild:latest

# pull the prebuild image in with a given name
FROM ${PREBUILD_IMAGE} AS prebuild


FROM ${BASE_IMAGE} as libfuzzer_base_build

COPY --from=prebuild /usr/local/bin/llvm-* /usr/local/bin/
COPY --from=prebuild /usr/local/lib/clang/18/lib/x86_64-unknown-linux-gnu/libclang_rt.fuzzer*.a /usr/local/lib/clang/18/lib/x86_64-unknown-linux-gnu/


# For Jazzer in out
COPY shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/shellphish_libfuzzer/wrapper.py /shellphish/wrapper.py
RUN chmod +x /shellphish/wrapper.py

# OSS-CRS: symlink_patch depends on TARGET_SPLIT_METADATA (Shellphish pipeline variable).
# Instead, compile_target handles wrapper.py symlink replacement after compile.
COPY shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/shellphish_libfuzzer/symlink_patch /shellphish/symlink_patch

# yq: download since original pipeline pre-copies it
RUN curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq && cp /usr/local/bin/yq /usr/bin/yq

# --- OSS-CRS glue ---
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh
COPY bin/compile_target /usr/local/bin/compile_target
RUN chmod +x /usr/local/bin/compile_target
CMD ["compile_target"]
