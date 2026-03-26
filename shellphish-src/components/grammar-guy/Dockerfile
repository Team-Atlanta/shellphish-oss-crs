# aixcc-build: aixcc-grammar-guy
ARG IMAGE_PREFIX=
ARG SOURCE_REPO=https://github.com/shellphish-support-syndicate/artiphishell
FROM ${IMAGE_PREFIX}aixcc-component-base
LABEL org.opencontainers.image.source=${SOURCE_REPO}
ARG ISOLATED=
RUN test -z "${ISOLATED}" || echo "deb [trusted=yes arch=amd64] http://apt-mirror-$(grep DISTRIB_RELEASE= /etc/lsb-release | cut -d= -f2 | sed 's/\./-/g'):$(grep DISTRIB_RELEASE= /etc/lsb-release | cut -d= -f2 | sed 's/\.//g') $(grep DISTRIB_CODENAME /etc/lsb-release | cut -d= -f2) main universe" > /etc/apt/sources.list

RUN apt update && apt install -y unar
RUN python3 -m pip install --upgrade pip
RUN pip3 install -e /shellphish/libs/crs-utils
RUN pip3 install tiktoken lxml commentjson

# OSS-CRS: adapt COPY path (build context is shellphish-oss-crs/)
COPY shellphish-src/components/grammar-guy /shellphish/grammar_guy/

RUN cd /shellphish/grammar_guy/tools/ && ./build.sh
RUN cd /shellphish/grammar_guy/ && pip3 install -e .
RUN cd /shellphish/libs/nautilus/ && ./build.sh

# [OSS-CRS glue] Map model names to external litellm-compatible names
RUN find /shellphish -name "*.py" -exec sed -i \
    -e 's/claude-4-sonnet/claude-sonnet-4-6/g' \
    -e 's/claude-4-opus/claude-opus-4-6/g' \
    -e 's/claude-3\.7-sonnet/claude-sonnet-4-6/g' \
    -e 's/claude-3\.5-sonnet/claude-3-5-sonnet-20241022/g' \
    -e 's/gpt-o4-mini/o4-mini/g' \
    -e 's/gpt-o3-mini/o3-mini/g' \
    -e 's/gpt-o3/o3/g' \
    -e 's/oai-//g' \
    {} + 2>/dev/null || true

# --- OSS-CRS glue ---
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh
COPY bin/run_grammar_guy /usr/local/bin/run_grammar_guy
RUN chmod +x /usr/local/bin/run_grammar_guy
CMD ["run_grammar_guy"]