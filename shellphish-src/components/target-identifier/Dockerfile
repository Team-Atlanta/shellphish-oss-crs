# aixcc-build: aixcc-target-identifier

ARG IMAGE_PREFIX=
ARG SOURCE_REPO=https://github.com/shellphish-support-syndicate/artiphishell

FROM ${IMAGE_PREFIX}aixcc-component-base
LABEL org.opencontainers.image.source=${SOURCE_REPO}

# OSS-CRS: adapt COPY path (build context is shellphish-oss-crs/)
COPY shellphish-src/components/target-identifier /shellphish/target-identifier

# --- OSS-CRS glue ---
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh
COPY bin/compile_target_identifier /usr/local/bin/compile_target_identifier
RUN chmod +x /usr/local/bin/compile_target_identifier
CMD ["compile_target_identifier"]