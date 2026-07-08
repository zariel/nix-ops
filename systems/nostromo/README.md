# Nostromo skeleton

`settings.nix` contains the opt-ins and site-specific values. The routed network,
Cilium peering, and managed storage are disabled until their prerequisites are
ready. Systemd initrd, resource accounting, NAS slice assignment, and a 64 GiB
ARC cap are active. No VM or builder services are included.

## Networking

Fill in the dummy-interface IPv4 identity, host ASN, physical permanent MAC addresses,
and both /31 endpoint pairs before enabling `networking.enable`. The first pair
is the existing NAS link; confirm it is still the intended allocation. The
bootstrap configuration retains the guest NIC name and must be corrected for a
bare-metal installation if routed networking remains disabled.

Networkd renames the physical ports to `uplink0` and `uplink1`. BIRD receives only
default routes from the upstreams, installs them with ECMP support, and advertises
the identity /32 on `dummy0`. Networkd creates this dummy interface independently
of uplink carrier. There is no static fallback default in routed mode. The
upstreams must accept the host ASN and advertised prefixes; MTU 9000 must work
end to end. Test each link independently, including return traffic. BIRD handles
link/session convergence without making host boot depend on both links being up.

Enable `networking.cilium.enable` only with the Kubernetes migration. Configure
Cilium to initiate eBGP from the specified local address to BIRD at 127.0.0.1:179,
using a distinct ASN and an explicit local source address. Leave Cilium's BGP
listener disabled. The configured CIDRs are the current pod and LoadBalancer
ranges; ClusterIP routes are not advertised. BIRD exports only these routes and
the host identity, with next-hop-self on each upstream. It does not install
Cilium-learned routes in the kernel. Their internal BIRD destination is blackhole
to avoid resolving a forwarding next hop for a speaker on the same host; these
entries must never be exported to the kernel. Upstream next-hop-self makes
Nostromo the forwarding destination. Validate advertisements and actual Cilium
forwarding before enabling upstream service announcements.

Set Kubernetes' node IP and API certificates to the stable identity. Adapt
Cilium's `devices`, API endpoint, node selectors, and cgroup configuration in
home-ops; this skeleton does not deploy Kubernetes or edit its manifests.

## SOPS and dataset mounts

Provision a dedicated age private key at `/var/lib/sops-nix/key.txt` on the boot
filesystem with root-only access. Keep a separate recovery identity outside this
host. Copy `.sops.yaml.example` to `.sops.yaml` and fill in the two public age
recipients. Encrypt a YAML document whose `bighorse-key` field contains the
existing ZFS hex key, preserving it as a quoted string. Save only the encrypted
document as `secrets.yaml`, then set `storage.sopsFile = ./secrets.yaml`.

Do not place a plaintext ZFS key or age private key in this repository or the Nix
store. SOPS decrypts the document at runtime. `bighorse-unlock.service` receives
the key through `LoadCredential`, after both the pool import and
`sops-install-secrets.service`. It leaves `keylocation=prompt` unchanged and does
not unload keys on a service restart.

Before enabling `storage.enable`:

- Preserve the TrueNAS recovery keys, Samba account state, and RustFS data from
  the separate `system` pool.
- Resolve the overlapping `music/downloads` and `music/downloads_old` mounts.
  The mount map selects `music/downloads`; verify this is the dataset to retain.
- Migrate the TrueNAS NFSv4 ACLs and complete the Samba authentication/group fixes.
- During the coordinated storage cutover, set `mountpoint=legacy` on the datasets
  listed in `storage.nix`. This configuration does not mutate dataset properties.
  Review the complete dataset inventory for other mounts that should be retained.
- Export the pool from TrueNAS and ensure Nostromo is its only owner.

Managed mode disables the global `zfs mount -a` service. NixOS owns the listed
mounts at their explicit `/mnt/bighorse` paths, independently of TrueNAS's altroot.
The `noauto,nofail` mounts are pulled in by NAS consumers after secrets are ready,
so they do not block `local-fs.target` or create a SOPS ordering cycle. Each mount
requires the unlock service. NAS consumers require their mounts and stop if those
mount units become inactive. A pool I/O failure that leaves mounts active still
requires ZFS monitoring; mount dependencies are not pool-health monitoring.

Future PVC provisioning should own a separate subtree in the NVMe pool. Add its
pool import and runtime mount dependencies when choosing the Kubernetes runtime
and CSI driver. The `data` pool is not imported or reformatted by this skeleton.

## Resources and boot

`storage.slice` contains the NAS userspace services and unlock service.
`background.slice` is available for future backup/maintenance jobs. Its lower
weights matter only after jobs are assigned to it. `kubepods.slice` is a resource
accounting scaffold; kubelet and the runtime must actually place pods there.
There are no blanket pod memory limits or automatic OOM-kill policies here.

The ARC cap applies independently of cgroup accounting. NFS kernel threads and
asynchronous ZFS I/O are not automatically controlled by userspace slice limits.
Measure pressure and latency before adding memory ceilings or I/O limits.

Systemd initrd retains the mdraid1/XFS root and mirrored GRUB bootloader. Before
deployment, test RAID assembly, boot with either boot SSD absent, missing-key
recovery, mount failures, and the shutdown ordering of storage consumers. The
config can be evaluated and BIRD's generated file parsed without activating it.
