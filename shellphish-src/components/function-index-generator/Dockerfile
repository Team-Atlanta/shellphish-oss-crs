# aixcc-build: aixcc-function-index-generator

ARG IMAGE_PREFIX=

FROM ${IMAGE_PREFIX}aixcc-component-base:latest
ARG SOURCE_REPO=https://github.com/shellphish-support-syndicate/artiphishell

LABEL org.opencontainers.image.source=${SOURCE_REPO}
WORKDIR /function-index-generator
COPY shellphish-src/components/function-index-generator /function-index-generator/
RUN pip install -e /shellphish/libs/crs-utils

# --- OSS-CRS glue ---
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh
COPY bin/run_func_index_gen /usr/local/bin/run_func_index_gen
RUN chmod +x /usr/local/bin/run_func_index_gen
CMD ["run_func_index_gen"]
