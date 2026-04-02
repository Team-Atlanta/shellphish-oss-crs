# aixcc-build: aixcc-antlr4-parser

ARG IMAGE_PREFIX=
ARG SOURCE_REPO=https://github.com/shellphish-support-syndicate/artiphishell

FROM ${IMAGE_PREFIX}aixcc-component-base

LABEL org.opencontainers.image.source=${SOURCE_REPO}
RUN pip install antlr4-tools antlr4-python3-runtime argparse tqdm GitPython jsonschema pyyaml numpy requests rich
RUN pip install -e /shellphish/libs/crs-utils
RUN git config --global --add safe.directory '*'
WORKDIR /shellphish/antlr4
# [OSS-CRS glue] Build context is shellphish-oss-crs/, not antlr4-guy/
COPY shellphish-src/components/antlr4-guy /shellphish/antlr4

# --- OSS-CRS glue ---
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh
COPY bin/run_antlr4_func_index /usr/local/bin/run_antlr4_func_index
RUN chmod +x /usr/local/bin/run_antlr4_func_index
CMD ["run_antlr4_func_index"]