# aixcc-build: aixcc-configuration-splitter
ARG IMAGE_PREFIX=
ARG SOURCE_REPO=https://github.com/shellphish-support-syndicate/artiphishell

FROM ${IMAGE_PREFIX}aixcc-component-base
LABEL org.opencontainers.image.source=${SOURCE_REPO}

# OSS-CRS: adapt COPY path (build context is shellphish-oss-crs/)
COPY shellphish-src/components/configuration-splitter/split_configurations.py /

# --- OSS-CRS glue ---
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh
COPY bin/compile_config_splitter /usr/local/bin/compile_config_splitter
RUN chmod +x /usr/local/bin/compile_config_splitter
CMD ["compile_config_splitter"]
