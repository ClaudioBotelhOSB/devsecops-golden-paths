# syntax=docker/dockerfile:1.9
# ==============================================================================
# Multi-stage, distroless, reproducible image for any Go cmd/ subcommand in
# this repository. Consumed by .github/workflows/backend-ci.yml.
#
# This Dockerfile is Go-specific. If your primary workload is not Go, fork
# it into a parallel file (e.g. Dockerfile.node, Dockerfile.python) and add
# a matching matrix entry + flavor workflow under .github/workflows/.
# ==============================================================================

ARG GO_VERSION=1.23.3

# ----------------------------------------------------------------------------
# Stage 1: build
# ----------------------------------------------------------------------------
FROM golang:${GO_VERSION}-bookworm AS builder

ARG BUILD_SHA=unknown
ARG BUILD_USER=""
# CMD selects which cmd/<dir> to compile. backend-ci.yml sets this per
# matrix entry (api | ttl-reaper | ...). Default: the primary API binary.
ARG CMD=api

WORKDIR /src

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download

COPY . .

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux \
    go build \
      -trimpath \
      -buildvcs=false \
      -ldflags "-s -w -X main.buildSHA=${BUILD_SHA} -X main.buildUser=${BUILD_USER}" \
      -o /out/app \
      ./cmd/${CMD}

# ----------------------------------------------------------------------------
# Stage 2: runtime (distroless, nonroot)
# ----------------------------------------------------------------------------
FROM gcr.io/distroless/static-debian12:nonroot

# Title / source / revision / authors are stamped at build time by
# docker/metadata-action in backend-ci.yml. Keep no hardcoded vendor here.

COPY --from=builder /out/app /app

USER nonroot:nonroot
ENTRYPOINT ["/app"]
