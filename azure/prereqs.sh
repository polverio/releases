#!/bin/sh 

export TEMPDIR=/tmp/polverio$$
mkdir -p $TEMPDIR 
pushd $TEMPDIR

export ARCHITECTURE="amd64"
if [ "$(uname -m)" = "aarch64" ]; then export ARCHITECTURE="arm64"; fi

export KUBE_VERSION="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
if [ "$KUBE_VERSION" = "" ]; then export KUBE_VERSION="v1.25.4"; fi

export CONTAINERD_VERSION="$(curl -vs https://github.com/containerd/containerd/releases/latest 2>&1 >/dev/null | grep -i '< Location:' | awk '{ print $3 }' | sed 's/https:\/\/github.com\/containerd\/containerd\/releases\/tag\/v//g' | sed 's/\r//g')"
if [ "$CONTAINERD_VERSION" = "" ]; then export CONTAINERD_VERSION="1.6.9"; fi

export RUNC_VERSION="$(curl -vs https://github.com/opencontainers/runc/releases/latest 2>&1 >/dev/null | grep -i '< Location:' | awk '{ print $3 }' | sed 's/https:\/\/github.com\/opencontainers\/runc\/releases\/tag\/v//g' | sed 's/\r//g')"
if [ "$RUNC_VERSION" = "" ]; then export RUNC_VERSION="1.1.4"; fi

export CRICTL_VERSION="$(curl -vs https://github.com/kubernetes-sigs/cri-tools/releases/latest 2>&1 >/dev/null | grep -i '< Location:' | awk '{ print $3 }' | sed 's/https:\/\/github.com\/kubernetes-sigs\/cri-tools\/releases\/tag\/v//g' | sed 's/\r//g')"
if [ "$CRICTL_VERSION" = "" ]; then export CRICTL_VERSION="1.25.0"; fi

export KUBERNETES_RELEASE_VERSION="$(curl -vs https://github.com/kubernetes/release/releases/latest 2>&1 >/dev/null | grep -i '< Location:' | awk '{ print $3 }' | sed 's/https:\/\/github.com\/kubernetes\/release\/releases\/tag\/v//g' | sed 's/\r//g')"
if [ "$KUBERNETES_RELEASE_VERSION" = "" ]; then export KUBERNETES_RELEASE_VERSION="0.1.4"; fi

CILIUM_VERSION="$(curl -vs https://github.com/cilium/cilium/releases/latest 2>&1 >/dev/null | grep -i '< Location:' | awk '{ print $3 }' | sed 's/https:\/\/github.com\/cilium\/cilium\/releases\/tag\/v//g' | sed 's/\r//g')"
if [ "$CILIUM_VERSION" = "" ]; then export CILIUM_VERSION="1.12.4"; fi

export ETH0IP4="$(ip -o -4 a | awk '$2 == "eth0" { print $4 }' | sed 's/\/[0-9]*//g')"

# Install system prerequisites and configure required external repositories
sudo tdnf install vim ethtool ebtables socat conntrack-tools apparmor-utils helm jq -y

curl -LO "https://dl.k8s.io/release/$KUBE_VERSION/bin/linux/$ARCHITECTURE/{kubectl,kubeadm,kubelet}"

sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
sudo install -o root -g root -m 0755 kubeadm /usr/local/bin/kubeadm
sudo install -o root -g root -m 0755 kubelet /usr/local/bin/kubelet

# https://kubernetes.io/docs/setup/production-environment/container-runtimes/#containerd
# https://github.com/containerd/containerd/blob/main/docs/getting-started.md
curl -LO "https://github.com/containerd/containerd/releases/download/v$CONTAINERD_VERSION/containerd-$CONTAINERD_VERSION-linux-$ARCHITECTURE.tar.gz"
sudo tar Cxzvf /usr/local containerd-$CONTAINERD_VERSION-linux-$ARCHITECTURE.tar.gz

curl -LO "https://github.com/kubernetes-sigs/cri-tools/releases/download/v$CRICTL_VERSION/crictl-v$CRICTL_VERSION-linux-$ARCHITECTURE.tar.gz"
tar Cxzvf . crictl-v$CRICTL_VERSION-linux-$ARCHITECTURE.tar.gz
sudo install -o root -g root -m 0755 crictl /usr/local/bin/crictl

sudo mkdir -p /etc/systemd/system
curl "https://raw.githubusercontent.com/containerd/containerd/main/containerd.service" | sudo tee /etc/systemd/system/containerd.service
sudo chmod 755 /etc/systemd/system/containerd.service

curl -LO "https://github.com/opencontainers/runc/releases/download/v$RUNC_VERSION/runc.$ARCHITECTURE"
sudo install -m 755 runc.$ARCHITECTURE /usr/local/bin/runc

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

# ## Configure required sysctl to persist across system reboots
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.ipv4.ip_forward = 1
# net.bridge.bridge-nf-call-iptables = 1
# net.bridge.bridge-nf-call-ip6tables = 1
EOF

# ## Apply sysctl parameters without reboot to current running enviroment
sudo sysctl --system

## Install ContainerD
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/            SystemdCgroup = false/            SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl daemon-reload
sudo systemctl enable --now containerd

curl -sSL "https://raw.githubusercontent.com/kubernetes/release/v$KUBERNETES_RELEASE_VERSION/cmd/kubepkg/templates/latest/deb/kubelet/lib/systemd/system/kubelet.service" | sed "s:/usr/bin:/usr/local/bin:g" | sudo tee /etc/systemd/system/kubelet.service
sudo mkdir -p /etc/systemd/system/kubelet.service.d
curl -sSL "https://raw.githubusercontent.com/kubernetes/release/v$KUBERNETES_RELEASE_VERSION/cmd/kubepkg/templates/latest/deb/kubeadm/10-kubeadm.conf" | sed "s:/usr/bin:/usr/local/bin:g" | sudo tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

sudo systemctl enable --now kubelet

# Configure iptables
sudo iptables -t nat -A POSTROUTING -m addrtype ! --dst-type local ! -d $ETH0IP4/24 -j MASQUERADE
sudo iptables -A INPUT -p tcp -m state --state NEW --match multiport --dports 1:65535 -j ACCEPT

cat <<EOF | sudo tee /tmp/kubeadm-init-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  taints:
  - key: "node.cilium.io/agent-not-ready"
    value: "true"
    effect: "NoExecute"
localAPIEndpoint:
  advertiseAddress: "$ETH0IP4"
  bindPort: 6443
skipPhases:
  - addon/kube-proxy
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
  podSubnet: 10.244.0.0/24
EOF

# configure kubelet on first nodev
sudo kubeadm init --config=/tmp/kubeadm-init-config.yaml --ignore-preflight-errors=NumCPU,Mem

# Untaint the control plane nodes so that workload can run on the control plane
export KUBECONFIG=/etc/kubernetes/admin.conf

# Install Cilium CNI
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --version $CILIUM_VERSION \
  --namespace kube-system \
  --set nodeinit.enabled=false \
  --set tunnel=disabled \
  --set operator.replicas=1 \
  --set ipam.mode=cluster-pool \
  --set hostPort.enabled=true \
  --set hostServices.enabled=true \
  --set nodePort.enabled=true \
  --set ingressController.enabled=true \
  --set egressGateway.enabled=true \
  --set ipv4NativeRoutingCIDR="$ETH0IP4/24" \
  --set containerRuntime.integration="containerd" \
  --set kubeProxyReplacement="strict" \
  --set k8sServiceHost="$ETH0IP4" \
  --set k8sServicePort="6443" \
  --set announce.loadbalancerIP=true \
  --set bpf.masquerade=true \
  --set ipam.operator.clusterPoolIPv4PodCIDRList={"10.244.0.0/24"} \
  --set ipv6.enabled=false \
  --set ipv4.enabled=true

cat <<EOF | sudo tee /tmp/cilium-policy.yaml
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: "allow-within-namespace"
EOF

# # Install Cilium CLI
# CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/master/stable.txt)
# CLI_ARCH=amd64
# if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
# curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
# sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
# sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
# rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}

# create a useful area for local disk storage
mkdir -p /pv
chmod -R 777 /pv

cat <<EOF | sudo tee /tmp/pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-data-local-1
  labels:
    type: local
spec:
  storageClassName:
  capacity:
    storage: 20Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: "/pv"
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-data-local-2
  labels:
    type: local
spec:
  storageClassName:
  capacity:
    storage: 20Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: "/pv"
EOF

kubectl apply -f /tmp/pv.yaml

# make sure the KUBECONFIG works when you sudo -i bash 
echo "export KUBECONFIG=/etc/kubernetes/admin.conf" >> /root/.bash_profile

# attempt to scale down coredns
kubectl scale deployment --replicas=1 coredns -n=kube-system

popd
rm -rf $TEMPDIR
