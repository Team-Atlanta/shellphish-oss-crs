# aixcc-build: aixcc-discovery-guy

ARG IMAGE_PREFIX=
ARG SOURCE_REPO=https://github.com/shellphish-support-syndicate/artiphishell
# [OSS-CRS glue] Removed: FROM ${IMAGE_PREFIX}aixcc-libs:latest AS libs (not built in prepare)
FROM ${IMAGE_PREFIX}aixcc-component-base
LABEL org.opencontainers.image.source=${SOURCE_REPO}

RUN mkdir /resources

RUN pip install --upgrade pip
RUN pip install ipython ipdb rich pyyaml gitpython pycparser docker sarif-tools fuzzing whatthepatch networkx
# [OSS-CRS glue] Dependencies for LLM-generated exploit scripts that DiscoveryGuy executes.
# Not a complete list — Shellphish's original base (aixcc-libs) is a private image we don't have,
# so we don't know the full set of pre-installed packages. These are added as-needed from runtime errors.
RUN pip install numpy fpdf2 pillow scapy cryptography PyJWT bitstring Faker pyelftools pefile macholib construct protobuf pyminizip xtarfile || true

# debugging env
ENV LOG_LLM=0
ENV LOG_LEVEL=WARNING

# agentlib env
ENV AGENTLIB_SAVE_FILES=off

# This should be set to 1 if you want to use the LLM API
ENV USE_LLM_API=1
# [OSS-CRS glue] LiteLLM key set at runtime via env
ENV LITELLM_KEY=

# [OSS-CRS glue] COPY debug-lib from source (not from aixcc-libs image)
COPY shellphish-src/libs/debug-lib /shellphish/libs/debug-lib
RUN pip install --editable /shellphish/libs/debug-lib

# Just create a new folder for shellphish stuff
# [OSS-CRS glue] COPY path: build context is shellphish-oss-crs/, not the component dir
COPY shellphish-src/components/discoveryguy/src /src/

# [OSS-CRS glue] Install libCRS (injected via additional_contexts by OSS-CRS)
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh
# [OSS-CRS glue] Install sandbox runner + glue entry point
COPY bin/sandbox_runner.py /usr/local/lib/python3.10/dist-packages/sandbox_runner.py
COPY bin/run_discoveryguy /usr/local/bin/run_discoveryguy
RUN chmod +x /usr/local/bin/run_discoveryguy

# [OSS-CRS glue] Map model names to external litellm-compatible names
RUN find /src /shellphish -name "*.py" -exec sed -i \
    -e 's/claude-4-sonnet/claude-sonnet-4-6/g' \
    -e 's/claude-4-opus/claude-opus-4-6/g' \
    -e 's/claude-3\.7-sonnet/claude-3-7-sonnet-20250219/g' \
    -e 's/claude-3\.5-sonnet/claude-3-5-sonnet-20241022/g' \
    -e 's/gpt-o4-mini/o4-mini/g' \
    -e 's/gpt-o3-mini/o3-mini/g' \
    -e 's/gpt-o3/o3/g' \
    -e 's/oai-//g' \
    {} + 2>/dev/null || true

WORKDIR /src

CMD ["run_discoveryguy"]
