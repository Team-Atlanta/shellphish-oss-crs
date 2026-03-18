# aixcc-build: aixcc-code-swipe
ARG IMAGE_PREFIX=
ARG SOURCE_REPO=https://github.com/shellphish-support-syndicate/artiphishell

FROM ${IMAGE_PREFIX}aixcc-component-base
LABEL org.opencontainers.image.source=${SOURCE_REPO}

RUN mkdir -p /shellphish/
COPY shellphish-src/components/code-swipe /shellphish/code-swipe/
WORKDIR /shellphish/code-swipe

# --- OSS-CRS glue ---
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh
COPY bin/run_code_swipe /usr/local/bin/run_code_swipe
RUN chmod +x /usr/local/bin/run_code_swipe
CMD ["run_code_swipe"]
