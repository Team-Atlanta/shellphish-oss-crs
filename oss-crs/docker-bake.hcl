group "default" {
  targets = ["crs-aflpp-prebuild"]
}

target "crs-aflpp-prebuild" {
  context    = "."
  dockerfile = "shellphish-src/libs/crs-utils/src/shellphish_crs_utils/oss_fuzz/instrumentation/aflpp/Dockerfile.prebuild"
  tags       = ["crs-aflpp-prebuild:latest"]
}
