#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Builds the Kubernetes controller image, or the gateway image, for Docker's
# architecture and loads it into the local Docker image store as
# openshell/$COMPONENT:$IMAGE_TAG.
#
# With cargo-zigbuild, it stages the controller binary the way release builds
# do. Otherwise, and always for the gateway, which needs its own features, it
# compiles the binary in a rust container, which needs no local
# cross-compiler, and packages it on the distroless cc base, because that
# binary links libgcc_s dynamically.
#
# Environment:
#   COMPONENT              k8s-controller (default) or gateway
#   IMAGE_TAG              image tag (default: dev)
#   K8S_CONTROLLER_BINARY  prebuilt linux controller binary to package instead
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_TAG="${IMAGE_TAG:-dev}"
COMPONENT="${COMPONENT:-k8s-controller}"
case "${COMPONENT}" in
  k8s-controller) BINARY=openshell-k8s-controller FEATURES="" SETUP=":" ;;
  # The gateway includes only the Kubernetes compute driver, and links the
  # policy prover's Z3, built from source as release builds do, which needs
  # cmake.
  gateway)
    BINARY=openshell-gateway
    FEATURES="--no-default-features --features telemetry,compute-driver-kubernetes,vendored-z3"
    SETUP="apt-get update -qq && apt-get install -y -qq cmake >/dev/null"
    ;;
  *) echo "unsupported COMPONENT: ${COMPONENT}" >&2; exit 1 ;;
esac
CC_BASE=gcr.io/distroless/cc-debian13@sha256:532c7a94f9e96ba9db75eb9388f4227751131c7cb0a411d1a8521af4096135de

case "$(docker info --format '{{.Architecture}}')" in
  x86_64 | amd64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) echo "unsupported Docker architecture" >&2; exit 1 ;;
esac
STAGE="${ROOT}/deploy/docker/.build/prebuilt-binaries/${ARCH}"
mkdir -p "${STAGE}"
BASE_ARGS=()
if [ -n "${K8S_CONTROLLER_BINARY:-}" ]; then
  install -m 0755 "${K8S_CONTROLLER_BINARY}" "${STAGE}/${BINARY}"
  BASE_ARGS=(--build-arg "K8S_CONTROLLER_BASE_IMAGE=${CC_BASE}")
elif [ "${COMPONENT}" = k8s-controller ] && command -v cargo-zigbuild >/dev/null 2>&1; then
  PREBUILT_ARCH="${ARCH}" "${ROOT}/tasks/scripts/stage-prebuilt-binaries.sh" "${COMPONENT}"
else
  BASE_ARGS=(--build-arg "K8S_CONTROLLER_BASE_IMAGE=${CC_BASE}")
  toolchain="$(awk -F'"' '/^channel/ {print $2}' "${ROOT}/rust-toolchain.toml")"
  echo "Building ${BINARY} for linux/${ARCH} in rust:${toolchain}-trixie..."
  docker run --rm -v "${ROOT}:/src" -w /src \
    -v openshell-k8s-ctl-target:/target -v openshell-k8s-ctl-cargo:/usr/local/cargo/registry \
    -e CARGO_TARGET_DIR=/target "rust:${toolchain}-trixie" \
    sh -c "${SETUP} && cargo build -q --locked --release -p ${BINARY} ${FEATURES} \
      && install -m 0755 /target/release/${BINARY} /src/deploy/docker/.build/prebuilt-binaries/${ARCH}/"
fi
cd "${ROOT}"
PREBUILT_AUTO_STAGE=0 IMAGE_TAG="${IMAGE_TAG}" DOCKER_PLATFORM="linux/${ARCH}" \
  tasks/scripts/docker-build-image.sh "${COMPONENT}" ${BASE_ARGS[@]+"${BASE_ARGS[@]}"} >/dev/null
echo "Built openshell/${COMPONENT}:${IMAGE_TAG}"
