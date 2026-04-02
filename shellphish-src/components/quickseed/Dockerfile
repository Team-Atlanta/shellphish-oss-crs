#aixcc-build:aixcc-quickseed
ARG IMAGE_PREFIX=
ARG SOURCE_REPO=https://github.com/shellphish-support-syndicate/artiphishell
FROM ${IMAGE_PREFIX}aixcc-component-base
LABEL org.opencontainers.image.source=${SOURCE_REPO}

ENV AGENTLIB_SAVE_FILES=0
WORKDIR /quickseed
# [OSS-CRS glue] Build context is shellphish-oss-crs/, not quickseed/
COPY shellphish-src/components/quickseed/QuickSeed QuickSeed
COPY shellphish-src/components/quickseed/tests tests
COPY shellphish-src/components/quickseed/requirements.txt requirements.txt
COPY shellphish-src/components/quickseed/setup.cfg setup.cfg
COPY shellphish-src/components/quickseed/setup.py setup.py
COPY shellphish-src/components/quickseed/scripts/run_quickseed.sh scripts/run_quickseed.sh
RUN chmod +x scripts/run_quickseed.sh


COPY shellphish-src/components/quickseed/scripts/prepare_quickseed.sh scripts/prepare_quickseed.sh
COPY shellphish-src/components/quickseed/scripts/prepare_quickseed.py scripts/prepare_quickseed.py
RUN chmod +x scripts/prepare_quickseed.sh

RUN pip install -e .
RUN pip install -e /shellphish/libs/graphquery/

COPY shellphish-src/components/quickseed/test_main.sh /test_main.sh
RUN chmod +x /test_main.sh

COPY shellphish-src/components/quickseed/scripts/aggregate_build_config.py scripts/aggregate_build_config.py

ENV USE_LLM_API=1
ENV LOG_LEVEL=info
ENV LOG_LLM=1

# ENV RETRIEVAL_API='http://beatty.unfiltered.seclab.cs.ucsb.edu:48751'
# ENV EMBEDDING_API='http://beatty.unfiltered.seclab.cs.ucsb.edu:49152'

ENV SRC="/tmp/src"
ENV CRASHES="/tmp/crashes"
ENV OUT="/tmp/out"

RUN mkdir -p ${SRC} ${CRASHES} ${OUT}

# [OSS-CRS glue] Map model names to external litellm-compatible names
# Same pattern as DiscoveryGuy Dockerfile: remap Shellphish model names and
# strip the oai- prefix that agentlib adds at runtime (USE_LLM_API=1).
RUN find /quickseed /shellphish -name "*.py" -exec sed -i \
    -e 's/claude-4-sonnet/claude-sonnet-4-6/g' \
    -e 's/claude-4-opus/claude-opus-4-6/g' \
    -e 's/claude-3\.7-sonnet/claude-3-7-sonnet-20250219/g' \
    -e 's/claude-3\.5-sonnet/claude-3-5-sonnet-20241022/g' \
    -e 's/gpt-o4-mini/o4-mini/g' \
    -e 's/gpt-o3-mini/o3-mini/g' \
    -e 's/gpt-o3/o3/g' \
    -e 's/oai-//g' \
    {} + 2>/dev/null || true

# --- OSS-CRS glue ---
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh
COPY bin/run_quickseed /usr/local/bin/run_quickseed
RUN chmod +x /usr/local/bin/run_quickseed
CMD ["run_quickseed"]
