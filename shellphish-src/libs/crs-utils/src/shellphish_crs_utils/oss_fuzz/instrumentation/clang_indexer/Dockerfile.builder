# OSS-CRS passes target_base_image; map to BASE_IMAGE for compatibility
ARG target_base_image
ARG BASE_IMAGE=${target_base_image}
ARG PREBUILD_IMAGE=crs-clang-indexer-prebuild:latest

FROM ${PREBUILD_IMAGE} AS prebuild
FROM ${BASE_IMAGE}

COPY --from=prebuild /shellphish/blobs/offline-packages /shellphish/blobs/offline-packages
RUN cd /shellphish/blobs/offline-packages && \
    apt install -y ./*.deb

RUN git config --global --add safe.directory '*' || true
RUN mkdir -p $SRC/shellphish

COPY shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/clang_indexer/clang-indexer $SRC/shellphish/clang-indexer
# target_info.py is dynamically copied by Shellphish's prepare_context_dir; do it here
COPY shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/target_info.py $SRC/shellphish/clang-indexer/src/clang_indexer/target_info.py
COPY --from=prebuild /shellphish/blobs/pypi-packages /shellphish/blobs/pypi-packages
RUN pip install --no-index --find-links=/shellphish/blobs/pypi-packages \
    joblib clang==18.1.8 && \
    pip install -e $SRC/shellphish/clang-indexer

# Bear
COPY --from=prebuild /shellphish/blobs/bear /usr/local/bin/bear
COPY --from=prebuild /shellphish/blobs/bear.tar.gz .
COPY shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/clang_indexer/bear_config.json /bear_config.json
RUN tar -xf bear.tar.gz -C /usr/local/lib/ && \
    chmod +x /usr/local/lib/bear/wrapper && \
    chmod +x /usr/local/bin/bear

RUN mv /usr/local/bin/compile /usr/local/bin/compile.old
COPY shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/clang_indexer/compile /usr/local/bin/compile

# --- OSS-CRS glue ---
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh
COPY bin/compile_clang_indexer /usr/local/bin/compile_clang_indexer
RUN chmod +x /usr/local/bin/compile_clang_indexer
CMD ["compile_clang_indexer"]
