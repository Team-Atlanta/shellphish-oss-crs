# aixcc-build: aixcc-semgrep
ARG IMAGE_PREFIX=
ARG SOURCE_REPO=https://github.com/shellphish-support-syndicate/artiphishell

FROM ${IMAGE_PREFIX}aixcc-component-base
LABEL org.opencontainers.image.source=${SOURCE_REPO}

RUN pip install semgrep

COPY shellphish-src/components/semgrep/rules /shellphish_semgrep_rules
COPY shellphish-src/components/semgrep/semgrep.py /semgrep.py

# --- OSS-CRS glue ---
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh
COPY bin/run_semgrep /usr/local/bin/run_semgrep
RUN chmod +x /usr/local/bin/run_semgrep
CMD ["run_semgrep"]
