Draft by Claude (2026-11-08), not reviewed yet.

kubelet restart-loops until kubeadm writes /var/lib/kubelet/config.yaml.
Setting the node up is deploy/k8s/README.md in this repo:

  1. Read-only checks first (swap, containerd SystemdCgroup, modules).
  2. doas kubeadm init --config deploy/k8s/kubeadm-config.yaml
  3. Copy /etc/kubernetes/admin.conf to ~/.kube/config.
  4. Install Cilium (helm), then local-path-provisioner.

If the node is not meant to run Kubernetes now, stop the loop instead:

  doas systemctl disable --now kubelet
