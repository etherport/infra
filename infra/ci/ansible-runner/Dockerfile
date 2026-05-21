# Ansible CI runner — used by self-hosted GitHub Actions workflows that
# run ansible playbooks against the homelab. Pre-baked image avoids
# `apt-get update + install` at the start of every workflow run, which
# was saturating the gh-runner VM's outbound network and causing the
# subsequent ansible SSH to PVE to time out (2026-05-21 incident).
#
# Used by `.github/workflows/ansible-proxmox.yml` via `container:`.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ansible \
        openssh-client \
        python3 \
        python3-pip \
        jq \
        ca-certificates \
        git \
    && rm -rf /var/lib/apt/lists/*

# Sanity: verify the collections we depend on are present.
# Ubuntu 24.04's `ansible` package bundles community.general + ansible.posix.
RUN ansible-galaxy collection list community.general >/dev/null \
    && ansible-galaxy collection list ansible.posix >/dev/null

# Working directory is set per-job by GitHub Actions; this is just a sane default.
WORKDIR /workspace
