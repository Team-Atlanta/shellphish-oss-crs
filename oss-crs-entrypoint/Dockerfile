# Entrypoint module: runs before fuzzers to compute CPU allocation.
# Writes allocation to SHARED_DIR, then exits.
ARG target_base_image
ARG BASE_IMAGE=ghcr.io/aixcc-finals/base-runner:v1.3.0

FROM ${BASE_IMAGE}

COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh
COPY oss-crs-entrypoint/run_entrypoint.sh /usr/local/bin/run_entrypoint.sh
RUN chmod +x /usr/local/bin/run_entrypoint.sh
ENTRYPOINT ["run_entrypoint.sh"]
