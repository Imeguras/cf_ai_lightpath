# Homelab cluster: single-node kubeadm + Cilium + local-path

A one-node Kubernetes cluster to run Lightpath's live mode. Good enough for a
homelab, not highly available: if the node is down, the cluster is down.

| Piece | Choice | Pinned by |
|---|---|---|
| Kubernetes | kubeadm, kubelet (already installed) | pacman (`kubeadm-config.yaml` pins no version) |
| Runtime | containerd (the same daemon Docker uses) | pacman |
| Networking | Cilium 1.20.4, kube-proxy replacement | `--version` in step 5 |
| Storage | local-path-provisioner v0.0.37, on the root NVMe | the URL in step 6 |

Every root command is for you to run. Nothing here touches ZFS.

## 0. Read-only checks (as micron)

```sh
kubeadm version -o short; kubelet --version; containerd --version
ls /etc/kubernetes /var/lib/kubelet 2>&1   # should be empty or missing (no earlier init)
swapon --show                               # swap stays; the kubelet config allows it
sysctl net.ipv4.ip_forward
lsmod | grep -E '^(overlay|br_netfilter)'
pacman -Q conntrack-tools socat ethtool cri-tools 2>&1   # kubeadm preflight needs these
```

## 1. Keep the node's IP stable

The API server certificate and kubeconfig carry the node IP. The server has
changed address by DHCP before, which would break the cluster. Make a **DHCP
reservation** for the LAN port's MAC on your router before `kubeadm init`.

## 2. Host prerequisites (root)

```sh
# Kernel modules and forwarding, now and on every boot.
printf 'overlay\nbr_netfilter\n' | doas tee /etc/modules-load.d/k8s.conf
doas modprobe overlay; doas modprobe br_netfilter
printf 'net.ipv4.ip_forward = 1\n' | doas tee /etc/sysctl.d/90-k8s.conf
doas sysctl --system

# containerd: let the kubelet manage cgroups through systemd.
# Only if /etc/containerd/config.toml does not exist yet:
containerd config default | doas tee /etc/containerd/config.toml
# Then set, under [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]:
#     SystemdCgroup = true
doas systemctl restart containerd
```

Restarting containerd can restart running Docker containers (Nextcloud,
ws_clock). Do it when that's fine.

Check: `doas crictl info | grep -i systemdcgroup` should print `true`.

## 3. Create the cluster (root)

```sh
doas kubeadm init --config deploy/k8s/kubeadm-config.yaml
```

kubelet is "stuck activating" today only because this step never ran; it
starts once kubeadm writes its config.

## 4. kubectl for micron

```sh
mkdir -p ~/.kube
doas cp /etc/kubernetes/admin.conf ~/.kube/config
doas chown micron: ~/.kube/config
kubectl get nodes        # NotReady until Cilium is in
```

## 5. Cilium

```sh
helm install cilium cilium --repo https://helm.cilium.io --version 1.20.4 \
  --namespace kube-system -f deploy/k8s/cilium-values.yaml
kubectl -n kube-system rollout status ds/cilium
kubectl get nodes        # Ready
```

## 6. Storage

```sh
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

Volumes live under `/opt/local-path-provisioner` on the root NVMe. They can
move to ZFS once ZFS is fixed.

## 7. Verify

```sh
kubectl get pods -A                      # everything Running
kubectl run probe --rm -it --image=busybox:1.37 --restart=Never -- nslookup kubernetes.default
```

## Known risks

- **Docker on the same host.** Docker sets the iptables FORWARD policy to DROP,
  which can block pod traffic. Cilium's eBPF datapath mostly avoids iptables;
  if pods can't reach each other or the internet, check this first.
- **Swap.** Allowed by `failSwapOn: false`, with `swapBehavior: NoSwap` so pods
  never swap.
- **Undo everything:** `doas kubeadm reset`, then remove `/etc/cni/net.d` and
  `~/.kube`. Docker and its containers are unaffected.
