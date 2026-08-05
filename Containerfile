FROM --platform=linux/arm64 debian:13-slim

ARG PVE_MANAGER_VERSION=9.2.9
ARG QEMU_SERVER_VERSION=9.2.4
ARG PVE_CONTAINER_VERSION=6.1.13
ARG PVE_FIREWALL_VERSION=6.0.5
ARG PVE_HA_MANAGER_VERSION=5.2.5

LABEL org.opencontainers.image.title="Nested Proxmox VE ARM64 Lab"
LABEL org.opencontainers.image.description="Unsupported, isolated Proxmox VE 9.2 ARM64 nested-virtualization lab"
LABEL org.opencontainers.image.source="local"
LABEL org.opencontainers.image.version="9.2"

ENV DEBIAN_FRONTEND=noninteractive

RUN test "$(dpkg --print-architecture)" = "arm64" \
    && rm -f /etc/dpkg/dpkg.cfg.d/docker \
    && apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        curl \
        dnsmasq-base \
        gnupg \
        iproute2 \
        iputils-ping \
        nftables \
        openssh-server \
        procps \
        systemd-sysv \
        wget \
    && install -d -m 0755 /usr/share/keyrings \
    && curl --fail --location --proto '=https' \
        https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
        --output /usr/share/keyrings/proxmox-archive-keyring.gpg \
    && echo "136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45  /usr/share/keyrings/proxmox-archive-keyring.gpg" \
        | sha256sum --check --strict \
    && printf '%s\n' \
        'Types: deb' \
        'URIs: http://download.proxmox.com/debian/pve' \
        'Suites: trixie' \
        'Components: pve-no-subscription' \
        'Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg' \
        > /etc/apt/sources.list.d/proxmox.sources \
    && apt-get update \
    && apt-get install --yes --no-install-recommends \
        "pve-manager=${PVE_MANAGER_VERSION}" \
        "qemu-server=${QEMU_SERVER_VERSION}" \
        "pve-container=${PVE_CONTAINER_VERSION}" \
        "pve-firewall=${PVE_FIREWALL_VERSION}" \
        "pve-ha-manager=${PVE_HA_MANAGER_VERSION}" \
        ifupdown2 \
        dnsmasq \
    && apt-mark hold \
        pve-manager qemu-server pve-container pve-firewall pve-ha-manager \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY config/interfaces /etc/network/interfaces
COPY config/nftables.conf /etc/nftables.conf
COPY config/dnsmasq-pve-lab.conf /etc/dnsmasq.d/pve-lab.conf
COPY config/sshd-pve-lab.conf /etc/ssh/sshd_config.d/pve-lab.conf
COPY scripts/pve-lab-bootstrap /usr/local/sbin/pve-lab-bootstrap
COPY systemd/pve-lab-bootstrap.service /etc/systemd/system/pve-lab-bootstrap.service

RUN chmod 0755 /usr/local/sbin/pve-lab-bootstrap \
    && printf 'pve-arm64-lab\n' >/etc/hostname \
    && printf 'net.ipv4.ip_forward=1\nnet.ipv6.conf.all.forwarding=1\n' \
        >/etc/sysctl.d/90-pve-lab-forwarding.conf \
    && passwd --lock root \
    && systemctl enable pve-lab-bootstrap.service nftables.service dnsmasq.service \
    && systemctl disable ssh.service \
    && rm -f /etc/machine-id \
    && touch /etc/machine-id \
    && install -d -m 0755 /var/lib/vz

STOPSIGNAL SIGRTMIN+3
VOLUME ["/var/lib/vz"]
ENTRYPOINT ["/sbin/init"]
