# OSS-CRS passes target_base_image; map to BASE_IMAGE for compatibility
ARG target_base_image
ARG BASE_IMAGE=${target_base_image}
ARG PREBUILD_IMAGE=crs-codeql-prebuild:latest

# pull the prebuild image in with a given name
FROM ${PREBUILD_IMAGE} AS codeql-prebuild

FROM ${BASE_IMAGE} AS final-builder

ENV CODEQL_VERSION="2.22.0"
COPY --from=codeql-prebuild /shellphish/codeql /shellphish/codeql
COPY --from=codeql-prebuild /shellphish/yq_linux_amd64 /usr/local/bin/yq
RUN chmod +x /usr/local/bin/yq

ENV PATH="/shellphish/codeql:${PATH}"

COPY shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/codeql/codeql_build.py /shellphish/codeql_build.py
RUN cp /usr/local/bin/compile /usr/local/bin/compile.old
COPY shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/codeql/compile /usr/local/bin/compile

# --- OSS-CRS glue ---
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh
COPY bin/compile_codeql /usr/local/bin/compile_codeql
RUN chmod +x /usr/local/bin/compile_codeql
CMD ["compile_codeql"]
