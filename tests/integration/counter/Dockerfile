# The counter demo actor of agent-substrate/substrate, built from the pinned release tag.
# The release does not publish the demo images. A test builds this one, so it
# runs a small stateful server that an actor can suspend and resume.
#
# Set SUBSTRATE_TAG and SUBSTRATE_COMMIT to the values in images/substrate-install/Dockerfile.
# The test fails if they differ.

# renovate: datasource=docker depName=golang
ARG GO_IMAGE=golang:1.27.3-bookworm@sha256:dc0963f32053e4bc451d24d87e3892d42d01021b61f093e98eb95c0352bb84b0
# renovate: datasource=docker depName=debian
ARG RUNTIME_IMAGE=debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS build
ARG TARGETOS=linux
ARG TARGETARCH
ARG SUBSTRATE_TAG=v1.0.0
ARG SUBSTRATE_COMMIT=b34fbee742906494b5eb4f1f36987176bf8770a4
ENV CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH}
RUN git clone --quiet --depth 1 --branch "${SUBSTRATE_TAG}" https://github.com/agent-substrate/substrate /src \
 && test "$(git -C /src rev-parse HEAD)" = "${SUBSTRATE_COMMIT}"
WORKDIR /src
RUN go build -trimpath -ldflags='-s -w' -o /out/counter ./demos/counter

FROM ${RUNTIME_IMAGE}
COPY --from=build /out/counter /counter
