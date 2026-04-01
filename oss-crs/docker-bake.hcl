group "default" {
  targets = ["crs-aflpp-prebuild", "crs-aijon-prebuild", "crs-libfuzzer-prebuild", "crs-jazzer-prebuild", "crs-clang-indexer-prebuild", "crs-codeql-prebuild", "crs-dependencies-base", "crs-component-base"]
}

target "crs-aflpp-prebuild" {
  context    = "."
  dockerfile = "shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/aflpp/Dockerfile.prebuild"
  tags       = ["crs-aflpp-prebuild:latest"]
}

target "crs-aijon-prebuild" {
  context    = "shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/aijon"
  dockerfile = "Dockerfile.c.builder"
  target     = "aijon-afl-compile-base"
  tags       = ["crs-aijon-prebuild:latest"]
}

target "crs-libfuzzer-prebuild" {
  context    = "."
  dockerfile = "shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/shellphish_libfuzzer/Dockerfile.prebuild"
  tags       = ["crs-libfuzzer-prebuild:latest"]
}

target "crs-jazzer-prebuild" {
  context    = "shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/jazzer"
  dockerfile = "Dockerfile.prebuild"
  args       = {
    OSS_FUZZ_BASE_BUILDER_IMAGE = "ghcr.io/aixcc-finals/base-builder:v1.3.0"
  }
  tags       = ["crs-jazzer-prebuild:latest"]
}

target "crs-clang-indexer-prebuild" {
  context    = "."
  dockerfile = "shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/clang_indexer/Dockerfile.prebuild"
  tags       = ["crs-clang-indexer-prebuild:latest"]
}

target "crs-codeql-prebuild" {
  context    = "."
  dockerfile = "shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/codeql/Dockerfile.prebuild"
  tags       = ["crs-codeql-prebuild:latest"]
}

target "crs-dependencies-base" {
  context    = "shellphish-src"
  dockerfile = "docker/Dockerfile.dependencies-base"
  tags       = ["aixcc-dependencies-base:latest"]
}

target "crs-component-base" {
  context    = "shellphish-src"
  dockerfile = "docker/Dockerfile.component-base"
  tags       = ["aixcc-component-base:latest"]
  contexts   = {
    "aixcc-dependencies-base:latest" = "target:crs-dependencies-base"
  }
}
