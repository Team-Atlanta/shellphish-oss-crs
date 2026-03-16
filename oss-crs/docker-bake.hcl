group "default" {
  targets = ["crs-aflpp-base"]
}

target "crs-aflpp-base" {
  context    = "."
  dockerfile = "oss-crs/dockerfiles/base.Dockerfile"
  tags       = ["crs-aflpp-base:latest"]
}
