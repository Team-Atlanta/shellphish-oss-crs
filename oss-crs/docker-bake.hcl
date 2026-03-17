group "default" {
  targets = ["crs-aflpp-prebuild", "crs-libfuzzer-prebuild"]
}

target "crs-aflpp-prebuild" {
  context    = "."
  dockerfile = "shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/aflpp/Dockerfile.prebuild"
  tags       = ["crs-aflpp-prebuild:latest"]
}

target "crs-libfuzzer-prebuild" {
  context    = "."
  dockerfile = "shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/shellphish_libfuzzer/Dockerfile.prebuild"
  tags       = ["crs-libfuzzer-prebuild:latest"]
}
