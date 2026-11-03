# Privileged VM matrix

Run lifecycle and firewall integration tests only in disposable full VMs with
their own kernel, systemd, cgroups, firewall, and qcow2 overlay. Do not run them
in privileged Docker/Distrobox containers or with a host cgroup namespace.

Validated environments:

- Ubuntu Server 26.04 LTS, nftables
- Arch Linux cloud image, nftables
- Ubuntu Server 26.04 LTS, iptables-legacy with ipset
- Fedora 44 cloud image, nftables with SELinux enforcing

The guest must receive the project source and pinned upstream archives through
SSH or a read-only data disk. QEMU user-mode networking should expose only an
SSH port on `127.0.0.1`; no bridge or tap interface is required.

For each nftables environment, verify:

1. Clean install creates the root-owned versioned layout, unit, command links, and the root-owned mode-644 `custom.d/50-sonar-udp-conntrack` hook.
2. `sonar use` starts exactly one expected `nfqws` process.
3. `sonar validate --json` passes all 22 pinned strategies.
4. The `postnat` and `prenat` chains each contain one TCP and one UDP rule for NFQUEUE 200.
5. `predefrag_nfqws` contains exactly one `sonar-udp-conntrack` rule, placed before the `notrack` rule.
6. A desynced UDP flow keeps its conntrack entry while the hook is present. Where the guest exposes conntrack introspection, the same probe without the hook must not keep the entry; images without it report `NOTE` and keep the structural checks.
7. Restart replaces the PID without duplicating firewall rules.
8. Active and inactive reinstall preserve strategy, autostart, and user lists.
9. Uninstall removes the process, unit, links, working tree, and firewall state.

For iptables, remove `nft` from `PATH`, select the legacy iptables alternative,
and verify that preflight rejects a missing `ipset`. With `ipset` installed,
require one TCP and one UDP NFQUEUE 200 rule in each of `POSTROUTING`, `INPUT`,
and `FORWARD`, followed by complete uninstall cleanup.

Capture `systemctl`, `journalctl`, process argv, firewall rules, and
`/proc/net/netfilter/nfnetlink_queue` on the first failure. Retries are diagnostic
only and do not replace the first failed result.

## Reproducible harness

The host runner pins every cloud image and upstream archive by URL and SHA-256,
creates a fresh qcow2 overlay and NoCloud seed, and exposes guest SSH only on
`127.0.0.1`. Each VM uses 2 vCPUs and 2 GiB RAM by default; `--jobs 2` can run
two disposable VMs concurrently.
QEMU is stopped and all per-run disks, keys, and seeds are removed after success
or failure. Prepared guest images are cached separately after one-time package
provisioning; normal lifecycle runs do not update the guest distribution.

Requirements: an x86_64 host, QEMU/KVM, `cloud-localds`, OpenSSH, curl, Git,
OpenSSL, tar, GNU coreutils, and write access to `/dev/kvm`. Prepare the cached
images, run the complete matrix, or run one profile from the repository root:

```bash
bash tests/vm/run.sh
bash tests/vm/run.sh --prepare-images
bash tests/vm/run.sh --rebuild-images
bash tests/vm/run.sh --jobs 2
bash tests/vm/run.sh ubuntu-nft
bash tests/vm/run.sh arch-nft
bash tests/vm/run.sh ubuntu-iptables-legacy
bash tests/vm/run.sh fedora-nft
```

Pinned inputs are declared in `images.tsv` and `upstream.tsv`. Downloads and
prepared images are stored under `${XDG_CACHE_HOME:-~/.cache}/zapret-sonar/`.
The production installer runs unchanged in the guest, while an allowlisted curl
fixture serves the exact verified upstream archives so a later upstream mutation
cannot change the test. `--jobs 2` runs at most two disposable VMs in parallel;
VMs are never persistent and consume no CPU or RAM outside a run.

Prepared images are invalidated when their pinned source checksum or provisioning
script changes. Ubuntu package sources use HTTPS. Arch provisioning uses the
dated Arch Linux Archive snapshot matching the pinned cloud image, avoiding a
time-dependent rolling upgrade. Fedora installs only missing packages from its
immutable base release repository and is tested with SELinux enforcing.
`--rebuild-images` forces a fresh preparation; `--probe-reboot <profile>` checks
only boot, reboot, SSH identity, and shutdown.

This is functional reproducibility, not a byte-identical package snapshot:
Ubuntu and Fedora provisioning can resolve newer package builds from their
release repositories. Prepared images record that provisioning result and are
reused until the source image or provisioning script changes.

On the first failure the guest captures systemd, journal, process, nftables,
iptables, and netfilter queue evidence. Together with the QEMU serial log it is
saved under `${XDG_STATE_HOME:-~/.local/state}/zapret-sonar/vm-artifacts/` with
mode `0700`. These local artifacts may contain raw logs and must not be uploaded
to public issues without sanitization.

Resource overrides are available through `ZF_VM_MEMORY`, `ZF_VM_CPUS`,
`ZF_VM_SSH_TIMEOUT`, `ZF_VM_PROVISION_TIMEOUT`, `ZF_VM_LIFECYCLE_TIMEOUT`,
`ZF_VM_CACHE_DIR`, `ZF_VM_INPUT_DIR`, and `ZF_VM_ARTIFACT_DIR`. Host and guest
operations have bounded timeouts, and QEMU receives a final `SIGKILL` fallback
if graceful shutdown fails. Do not add VM autostart or a persistent daemon:
outside a run there must be no QEMU process, allocated guest RAM, forwarded SSH
port, overlay, seed, or temporary SSH key.
