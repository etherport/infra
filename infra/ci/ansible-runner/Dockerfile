# Ansible CI runner — used by self-hosted GitHub Actions workflows that
# run ansible playbooks against the homelab. Pre-baked image avoids
# `apt-get update + install` at the start of every workflow run, which
# was saturating the gh-runner VM's outbound network and causing the
# subsequent ansible SSH to PVE to time out (2026-05-21 incident).
#
# Used by `.github/workflows/ansible-proxmox.yml` via `container:`.

FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ansible \
        openssh-client \
        python3 \
        python3-pip \
        jq \
        curl \
        ca-certificates \
        git \
    && rm -rf /var/lib/apt/lists/*

# SOPS binary + collection — playbooks decrypt *.sops.yaml via
# community.sops.load_vars (delegate_to: localhost), e.g. wireguard.yml. The
# age private key is supplied at runtime via the SOPS_AGE_KEY env (set from a
# GH secret in the ansible workflows). Arch-aware (amd64/arm64).
# Keep SOPS_VERSION in sync with the canonical pin in
# .github/actions/setup-sops/action.yml (the workflow-side single source of
# truth). This Dockerfile can't reuse that composite action (it's a build, not
# a workflow) and is arch-dependent, so it's pinned separately by version.
# TODO(M61/H30): add per-arch sha256 verification here too (setup-sops already
# checksum-verifies the amd64 binary).
ARG SOPS_VERSION=v3.9.4
RUN ARCH="$(dpkg --print-architecture)" \
    && curl -fsSL -o /usr/local/bin/sops \
        "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${ARCH}" \
    && chmod +x /usr/local/bin/sops \
    && sops --version \
    && ansible-galaxy collection install community.sops -p /usr/share/ansible/collections

# Sanity: verify the collections we depend on are present.
# Ubuntu 24.04's `ansible` package bundles community.general + ansible.posix.
RUN ansible-galaxy collection list community.general >/dev/null \
    && ansible-galaxy collection list ansible.posix >/dev/null \
    && ansible-galaxy collection list community.sops >/dev/null \
    && command -v sops >/dev/null

# Working directory is set per-job by GitHub Actions; this is just a sane default.
WORKDIR /workspace
