# vistral-ssm

SSM document definitions for zero-touch cluster buildout. These documents are the single source of truth — `vistral-cdk` reads from this directory and registers them with AWS SSM on deploy.

## Zero-Touch Build Flow

When a device boots from a USB created by `vistral-bootstrap`, it registers with AWS SSM. A single **Automation runbook** (`vistral-node-buildout`) orchestrates the full buildout in strict order:

```
USB Boot → SSM Registration → State Manager triggers vistral-node-buildout
  │
  ├─ Step 1: vistral-t2-bootstrap       (onFailure: Continue)
  │           Detect Apple T2 hardware, install kernel, reboot
  │
  ├─ Step 2: Wait 60s for reboot
  │
  ├─ Step 3: vistral-k8s-join           (onFailure: Abort, maxAttempts: 2)
  │           Detect role from hostname, join K8s cluster
  │
  └─ Step 4: vistral-wol-setup           (onFailure: Continue)
              Enable Wake-on-LAN on GPU workers for powernap
```

Each step waits for the previous one to complete. If K8s join fails, the runbook aborts — no point configuring WOL on a node that isn't in the cluster. T2 bootstrap and WOL setup are allowed to fail gracefully (non-Apple hardware, non-GPU nodes).

## Documents

### Orchestrator

| Document | Type | Purpose |
|----------|------|---------|
| `vistral-node-buildout` | Automation | Runs build steps in order with success/failure control |

### Build Steps (Command documents, called by orchestrator)

| Document | Target | Guard |
|----------|--------|-------|
| `vistral-t2-bootstrap` | All nodes | Skips if T2 kernel already installed |
| `vistral-k8s-join` | All nodes | Skips if `/etc/kubernetes/kubelet.conf` exists |
| `vistral-k8s-generate-token` | Control planes | Called by k8s-join when token expires |
| `vistral-dns-setup` | All nodes | Skips if CoreDNS running or resolv.conf configured |

### Operations (on-demand, manual trigger)

| Document | Target | Purpose |
|----------|--------|---------|
| `vistral-cluster-update` | Primary control plane | Helm/kubectl updates, cert rotation, secret refresh |
| `vistral-worker-reset` | Workers only | Self-drain, reset kubeadm, auto-rejoin on next cycle |

## Deployment

All documents are deployed via `vistral-cdk`:

```bash
cd vistral-cdk && cdk deploy --all --profile Vistral
```

CDK reads the YAML files from this directory, creates them as SSM documents, and sets up the State Manager association that triggers `vistral-node-buildout` every 30 minutes on all instances tagged `k8s-cluster=vistral`.

## Dependencies

- `vistral-cdk` — Registers documents, creates IAM roles, State Manager associations
- `vistral-cluster` — K8s scripts that `vistral-k8s-join` clones and executes
- `vistral-bootstrap` — Creates USB drives with embedded SSM activation credentials
- `vistral-image-ssm` — EventBridge rules that trigger `vistral-t2-bootstrap` on registration
