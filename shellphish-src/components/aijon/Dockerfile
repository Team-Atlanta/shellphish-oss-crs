# aixcc-build: aixcc-aijon

ARG IMAGE_PREFIX=
ARG SOURCE_REPO=https://github.com/shellphish-support-syndicate/artiphishell
# [OSS-CRS glue] Removed: FROM ${IMAGE_PREFIX}aixcc-libs:latest AS libs (not built in prepare)
FROM ${IMAGE_PREFIX}aixcc-component-base
LABEL org.opencontainers.image.source=${SOURCE_REPO}


RUN pip install --upgrade pip
RUN pip install ipython ipdb rich pyyaml unidiff loguru

# [OSS-CRS glue] COPY aijon-lib from source (not from aixcc-libs image)
COPY shellphish-src/libs/aijon-lib /shellphish/libs/aijon-lib
RUN pip install --editable /shellphish/libs/aijon-lib

WORKDIR /aijon

# [OSS-CRS glue] COPY path: build context is shellphish-oss-crs/, not the component dir
COPY shellphish-src/components/aijon/ /aijon/

# [OSS-CRS glue] Install libCRS (injected via additional_contexts by OSS-CRS)
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh

# [OSS-CRS glue] Install glue entry point
COPY bin/run_aijon_instrumentation /usr/local/bin/run_aijon_instrumentation
RUN chmod +x /usr/local/bin/run_aijon_instrumentation

# [OSS-CRS glue] Disable OTEL (no collector in OSSCRS)
ENV OTEL_SDK_DISABLED=true

# [OSS-CRS glue] LiteLLM key set at runtime via env
ENV LITELLM_KEY=
ENV USE_LLM_API=1
# Disable agentlib file saving to prevent large amount of debugging files in container
ENV AGENTLIB_SAVE_FILES=off

# [OSS-CRS glue] Map model names to external litellm-compatible names
RUN find /aijon /shellphish -name "*.py" -exec sed -i \
    -e 's/claude-4-sonnet/claude-sonnet-4-6/g' \
    -e 's/claude-4-opus/claude-opus-4-6/g' \
    -e 's/claude-3\.7-sonnet/claude-sonnet-4-6/g' \
    -e 's/claude-3\.5-sonnet/claude-3-5-sonnet-20241022/g' \
    -e 's/gpt-o4-mini/o4-mini/g' \
    -e 's/gpt-o3-mini/o3-mini/g' \
    -e 's/gpt-o3/o3/g' \
    -e 's/oai-//g' \
    {} + 2>/dev/null || true

CMD ["run_aijon_instrumentation"]
