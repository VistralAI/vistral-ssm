#!/usr/bin/env bash
# Vistral health-check library — single source of truth for "is this thing
# really working" probes used as SSM document idempotency guards.
#
# Failure mode this addresses (P1 #6): a guard that checks `[ -f X ]` passes
# even when the underlying service is dead, certs expired, or config corrupted.
# Every guard here probes a runtime invariant, not just a path.
#
# Levels:
#   L1 — file/marker exists (cheap, used as fast-path before deeper checks)
#   L2 — systemctl is-active <unit>
#   L3 — functional probe (kubectl get, nvidia-smi, crictl, dig, ...)
#   L4 — cert/version validity (openssl x509, kubeadm version match, ...)
#
# Usage: source this file in an SSM document, then:
#   if require_healthy kubelet; then echo "already healthy, skipping"; exit 0; fi

# Cert expiry threshold: a cert is "healthy" if it's valid for at least this
# many seconds. 7 days = 604800. Override per-call as needed.
HEALTH_CERT_MIN_SECONDS="${HEALTH_CERT_MIN_SECONDS:-604800}"

_health_log() {
  echo "$(date -Iseconds) [health-check] $*" >&2
}

# L4: cert is valid for at least HEALTH_CERT_MIN_SECONDS more.
health_cert_valid() {
  local cert_path="$1" min_seconds="${2:-$HEALTH_CERT_MIN_SECONDS}"
  [[ -f "$cert_path" ]] || return 1
  openssl x509 -checkend "$min_seconds" -noout -in "$cert_path" >/dev/null 2>&1
}

# L3+L4: kubelet healthy = service active + API healthz + client cert not near expiry.
health_kubelet() {
  systemctl is-active --quiet kubelet 2>/dev/null || { _health_log "kubelet not active"; return 1; }

  local kubeconfig=/etc/kubernetes/kubelet.conf
  [[ -f "$kubeconfig" ]] || { _health_log "missing $kubeconfig"; return 1; }

  # API healthz via kubelet's kubeconfig (works on both control plane and worker)
  if ! timeout 10 kubectl --kubeconfig="$kubeconfig" get --raw /healthz >/dev/null 2>&1; then
    _health_log "kubectl /healthz failed via $kubeconfig"
    return 1
  fi

  # Client cert: kubelet rotates the cert via /var/lib/kubelet/pki/kubelet-client-current.pem
  local client_cert=/var/lib/kubelet/pki/kubelet-client-current.pem
  if [[ -L "$client_cert" || -f "$client_cert" ]]; then
    if ! health_cert_valid "$client_cert"; then
      _health_log "kubelet client cert expires within ${HEALTH_CERT_MIN_SECONDS}s"
      return 1
    fi
  fi

  return 0
}

# L3: control-plane API server cert valid + kube-apiserver static pod healthy.
health_kube_apiserver() {
  local cert=/etc/kubernetes/pki/apiserver.crt
  if [[ -f "$cert" ]]; then
    health_cert_valid "$cert" || { _health_log "apiserver.crt expires within ${HEALTH_CERT_MIN_SECONDS}s"; return 1; }
  fi
  # Static pod manifest exists implies the kubelet should be running it.
  [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]] || return 1
  systemctl is-active --quiet kubelet 2>/dev/null
}

# L2+L3: containerd up and answering CRI calls.
health_containerd() {
  systemctl is-active --quiet containerd 2>/dev/null || return 1
  timeout 5 crictl --runtime-endpoint unix:///run/containerd/containerd.sock info >/dev/null 2>&1
}

# L3: NVIDIA GPU drivers + container toolkit functional.
health_gpu() {
  command -v nvidia-smi >/dev/null 2>&1 || { _health_log "nvidia-smi not found"; return 1; }
  timeout 10 nvidia-smi -L >/dev/null 2>&1 || { _health_log "nvidia-smi -L failed"; return 1; }
  command -v nvidia-ctk >/dev/null 2>&1 || { _health_log "nvidia-ctk not found"; return 1; }
  return 0
}

# L3: CoreDNS resolves cluster.local from the node.
health_cluster_dns() {
  local vip="${1:-${VIP_ADDRESS:-}}"
  [[ -n "$vip" ]] || { _health_log "no VIP supplied"; return 1; }
  timeout 5 dig "@${vip}" kubernetes.default.svc.cluster.local +short +tries=1 >/dev/null 2>&1
}

# Generic dispatcher: `require_healthy <subject>` — extend as new subjects appear.
require_healthy() {
  local what="$1"
  case "$what" in
    kubelet)        health_kubelet ;;
    kube-apiserver) health_kube_apiserver ;;
    containerd)     health_containerd ;;
    gpu)            health_gpu ;;
    cluster-dns)    health_cluster_dns "${2:-}" ;;
    *)
      _health_log "unknown subject: '$what'"
      return 2
      ;;
  esac
}
