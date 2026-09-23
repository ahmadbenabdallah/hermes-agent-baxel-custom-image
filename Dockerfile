# Hermes Agent — custom Blaxel sandbox image
# Dependency set validated by hand on a bare Alpine 3.21 container before
# baking into this template (see notes below for why each package is here).
#
# SECURITY NOTE: both base images below are pinned by digest, not just tag.
# A tag like `alpine:3.21` or `sandbox:latest` can be silently repointed at
# a different (or compromised) image by the upstream maintainer or registry
# without your Dockerfile changing at all — Dependabot's Docker updates
# won't catch that since nothing about the tag changed. Pinning by digest
# means this build only ever uses the exact bytes verified in CI.
# Update these digests deliberately (e.g. via `docker pull <image> && docker
# inspect --format='{{index .RepoDigests 0}}' <image>`) rather than letting
# them drift silently.

FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

# Alpine's default shell is ash (busybox), not bash. Set pipefail explicitly
# so any RUN using a pipe (e.g. curl | bash below) fails the build if the
# LEFT side of the pipe fails, not just the right side — without this, a
# broken/truncated curl download could silently report success because bash
# still exits 0 on empty input.
SHELL ["/bin/ash", "-o", "pipefail", "-c"]

# --- Blaxel sandbox API (REQUIRED) ------------------------------------------
# Every Blaxel sandbox image must include this binary — it's what gives you
# process management, file operations, and the /process HTTP API that the
# entrypoint below calls into. Without it the sandbox never becomes usable.
COPY --from=ghcr.io/blaxel-ai/sandbox:latest@sha256:9ba865445c947e9a2f575aabd6beb77f8391281a5d21aa54a40225c461f85144 /sandbox-api /usr/local/bin/sandbox-api

# --- System packages ---------------------------------------------------------
# nodejs/npm    : Alpine's musl-native build. Hermes's installer bundles its
#                 own managed Node 26, but that's a glibc build and fails on
#                 musl with "cannot execute: required file not found".
# python3       : must resolve as `python3` on PATH — node-gyp shells out
#                 looking for a *system* python, separate from the uv-managed
#                 Python Hermes installs for itself into its own venv.
# build-base,
# gcc, g++, make,
# linux-headers : node-gyp needs a real C/C++ toolchain to compile native
#                 modules from source. node-pty (used for Hermes's terminal
#                 tooling) has no prebuilt binary for linux-x64-musl, so this
#                 is not optional — npm install fails without it.
# git           : required to clone the hermes-agent repo during install.
# ca-certificates: avoids TLS trust-store gaps that manifest as silent
#                 timeouts rather than clear cert errors.
# ripgrep, ffmpeg: installer warns and degrades (grep fallback / no TTS)
#                 without these — cheap to include upfront.
# openssh-client : installer tries SSH clone before falling back to HTTPS.
# bash, curl    : installer requires bash; curl fetches the install script.
# hadolint ignore=DL3018
# Version-pinning apk packages is intentionally skipped here: Alpine package
# versions shift with every base-image bump, and hard-pinning would make
# this Dockerfile break on every Dependabot-triggered Alpine update instead
# of just picking up the new compatible versions automatically.
RUN apk add --no-cache \
    bash \
    curl \
    git \
    ca-certificates \
    python3 \
    py3-pip \
    nodejs \
    npm \
    build-base \
    gcc \
    g++ \
    make \
    linux-headers \
    ripgrep \
    ffmpeg \
    openssh-client \
    netcat-openbsd

# hadolint ignore=DL3059
# Fail the build fast if any of the above didn't land correctly
RUN node -v && npm -v && python3 -V && git --version

# --- Hermes Agent install ----------------------------------------------------
# hadolint ignore=DL3059
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash

# Explicitly re-run the Node.js dependency install from the correct directory.
# The installer's own attempt runs from the wrong cwd in some environments
# and silently no-ops; doing it here as a separate layer means a broken
# native-module compile fails the image build loudly instead of shipping
# a sandbox with half-installed browser tools.
WORKDIR /usr/local/lib/hermes-agent
RUN npm install

# Sanity check the full stack (Python + Node) resolves before shipping.
# Must use the venv's own Python — Hermes installs its deps (pyyaml, etc.)
# into /usr/local/lib/hermes-agent/venv via uv, not into system python.
# hadolint ignore=DL3059
RUN ./venv/bin/python run_agent.py --help

# --- Entrypoint ---------------------------------------------------------------
WORKDIR /root
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
