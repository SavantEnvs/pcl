# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) for PCL (Point Cloud Library) — builds ON TOP of the
# org C/C++ base image (ghcr.io/savantenvs/base), which already provides debian + clang/llvm +
# libFuzzer/afl++ + the identities + the build-contract ENV.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t pcl-commit:test .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
ARG SANITIZER_FLAGS
# Coverage (optional, off by default): instrument the TEST build only.
ARG COVERAGE_FLAGS=
# Build parallelism (optional). build.sh falls back to nproc when unset.
ARG MAYHEM_JOBS=

# PCL's own build deps (only what the fuzzed subsystems — common/octree/io — need: Eigen3,
# Boost (header-only + iostreams/filesystem for pcl_io), and libgtest-dev for the io unit tests
# mayhem/test.sh runs). Re-pin apt sources to SOURCE_DATE_EPOCH first when set, for reproducibility.
USER root
RUN [ -z "$SOURCE_DATE_EPOCH" ] || repro-sources-list.sh ; \
    apt-get update && apt-get install -yq --no-install-recommends \
        libeigen3-dev \
        libboost-dev \
        libboost-iostreams-dev \
        libboost-filesystem-dev \
        libgtest-dev \
        libbz2-dev \
        liblzma-dev \
        libzstd-dev \
    && rm -rf /var/lib/apt/lists/*
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history) is
# copied to /mayhem as `mayhem`; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run PCL's own io/common/octree unit tests at build time — a failing suite fails the image build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
