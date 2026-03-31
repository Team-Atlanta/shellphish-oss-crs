# aixcc-build: aixcc-coverageguy

# this image comes with crs-utils
# to build aixcc-component-base locally cd to shellphish-crs/pipelines/local_run and run rebuild_local.sh

ARG IMAGE_PREFIX=
ARG SOURCE_REPO=https://github.com/shellphish-support-syndicate/artiphishell

####################################################################################################
####################################################################################################
FROM ${IMAGE_PREFIX}aixcc-component-base as coverageguy-base
LABEL org.opencontainers.image.source=${SOURCE_REPO}

RUN pip install pympler

RUN mkdir -p /shellphish/coverageguy
# [OSS-CRS glue] COPY path: build context is shellphish-oss-crs/, not the component dir
COPY shellphish-src/components/coverage-guy /shellphish/coverageguy/

# [OSS-CRS glue] Update coveragelib with OSSCRS trace() ordering fix
COPY shellphish-src/libs/coveragelib /shellphish/libs/coveragelib
RUN pip3 install -e /shellphish/libs/coveragelib

# [OSS-CRS glue] Update analysis-graph (component-base has neomodel without version pin;
# our pyproject.toml pins neomodel<6 for API compatibility)
COPY shellphish-src/libs/analysis-graph /shellphish/libs/analysis-graph
RUN pip3 install -e /shellphish/libs/analysis-graph

# [OSS-CRS glue] libCRS + glue entry point
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh
COPY bin/run_coverage_guy /usr/local/bin/run_coverage_guy
RUN chmod +x /usr/local/bin/run_coverage_guy /shellphish/coverageguy/run.sh

CMD ["run_coverage_guy"]