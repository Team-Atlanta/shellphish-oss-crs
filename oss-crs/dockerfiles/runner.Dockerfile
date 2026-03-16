# Runner: downloads AFL++ build output and runs afl-fuzz.
#
# Uses base-runner which has the sanitizer runtimes needed by instrumented binaries.

FROM gcr.io/oss-fuzz-base/base-runner

RUN apt-get update && apt-get install -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# Install libCRS
COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh

COPY bin/run_fuzzer.sh /usr/local/bin/run_fuzzer.sh
RUN chmod +x /usr/local/bin/run_fuzzer.sh

ENTRYPOINT ["/usr/local/bin/run_fuzzer.sh"]
