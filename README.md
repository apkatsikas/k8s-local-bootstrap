# Kubernetes Local Bootstrap

A working local Kubernetes stack you can use as a starting point for any project.
Out of the box you get a Node.js app running at `https://api.localhost` with:

- **TLS** — self-signed cert managed by cert-manager, HTTP → HTTPS redirect
- **Gateway API** — modern Kubernetes ingress via Envoy Gateway (CNCF project)
- **Helm** — all resources managed as two charts (`infra` and `api`)
- **KIND** — a real Kubernetes cluster running locally inside Docker
- **No local Node.js required** — npm install runs in Docker

The patterns here (Gateway API, cert-manager, namespacing, Helm) are
production-grade. The local-only parts are clearly marked and easy to swap
when you move to a cloud cluster.

---

## Prerequisites

| Tool | Purpose |
|---|---|
| [Docker](https://docs.docker.com/get-docker/) | Runs KIND and builds images |
| [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) | Local Kubernetes cluster |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | Talks to the cluster |
| [helm](https://helm.sh/docs/intro/install/) | Deploys the charts |

---

## Quick Start

```bash
make all
```

This runs the full setup in order:
1. Creates the KIND cluster
2. Installs Envoy Gateway (includes Gateway API CRDs) and cert-manager
3. Installs npm dependencies (via Docker)
4. Builds the Docker image
5. Loads the image into KIND and deploys both Helm charts

Once complete, visit `https://api.localhost` in your browser. Accept the
self-signed certificate warning and you'll see the app.

---

## Dev Loop

After the initial setup, iterating is fast:

```bash
make build && make deploy
```

- `make build` — rebuilds the Docker image from `src/`
- `make deploy` — loads the new image into KIND, upgrades the Helm charts,
  and restarts the deployment so pods pick up the new image

Other useful targets:

```bash
make logs     # tail logs from the api pod
make status   # show pods, services, gateway, and routes in the api namespace
```

---

## How It Works

### Request Path

```
Browser
  → localhost:443
  → KIND extraPortMapping  (host → KIND node container)
  → Envoy hostPort         (KIND node → Envoy Gateway proxy pod)
  → Gateway                (TLS termination)
  → HTTPRoute              (matches api.localhost → api Service)
  → Service                (stable address → pod, load balances if replicas > 1)
  → Pod                    (your app)
```

Most of the complexity exists to replicate what a cloud load balancer does
automatically. Each step is explained below.

---

### The Cluster: KIND

KIND (Kubernetes in Docker) runs a real Kubernetes cluster inside a Docker
container. `kind-cluster/kind.yaml` maps ports 80 and 443 from your machine
into the KIND node container:

```yaml
extraPortMappings:
  - containerPort: 80
    hostPort: 80
  - containerPort: 443
    hostPort: 443
```

> **Local only.** In a cloud cluster, a managed load balancer sits in front.
> No port mappings needed.

---

### Port Forwarding: EnvoyProxy

`extraPortMappings` gets traffic into the KIND node, but your app isn't
running there — it's running in a pod. `charts/infra/templates/gatewayparameters.yaml`
defines an `EnvoyProxy` resource that bridges this with `hostPort`:

```yaml
containers:
  - name: envoy
    ports:
      - containerPort: 80
        hostPort: 80
      - containerPort: 443
        hostPort: 443
```

`hostPort` binds the container's port directly to the node's port, so traffic
arriving at the KIND node goes straight into the Envoy proxy pod.

It also sets the Gateway Service type to `ClusterIP`:

```yaml
envoyService:
  type: ClusterIP
```

Normally Envoy Gateway creates a `LoadBalancer` Service to get an external IP
from the cloud. There's no cloud here, so we bypass it.

> **Local only.** Remove `gatewayparameters.yaml` in production and Envoy
> Gateway will create a real `LoadBalancer` Service backed by the cloud provider.

---

### Namespaces

Two namespaces keep the networking layer and application layer separate:

- `default` — the Gateway lives here
- `api` — your app (Deployment, Service, Certificate) lives here

This mirrors how real clusters are often organized, where platform
infrastructure is managed separately from individual applications.

---

### The App

`charts/api/templates/deployment.yaml` runs your Node.js app as a pod.
`imagePullPolicy: Never` tells Kubernetes not to pull from a registry — the
image must already be present on the node, loaded there by `kind load
docker-image`.

`charts/api/templates/service.yaml` gives the Deployment a stable ClusterIP
inside the cluster. Routes target the Service, not individual pods.

> **Local only: `imagePullPolicy: Never` and `kind load`.** In production,
> images live in a registry (ECR, GCR, Docker Hub) and Kubernetes pulls them
> automatically. Use `imagePullPolicy: IfNotPresent`.

---

### Gateway API

The **Gateway API** is the modern Kubernetes standard for ingress, replacing
the older `Ingress` resource. It splits responsibilities across three resources:

**GatewayClass** (`charts/infra/templates/gatewayclass.yaml`) — declares
which controller implements gateways. Here it's Envoy Gateway. It also
references the `EnvoyProxy` resource for the KIND-specific overrides.

**Gateway** (`charts/api/templates/gateway.yaml`) — the gateway instance.
Declares two listeners: port 80 (HTTP) and port 443 (HTTPS with TLS
termination using the `api-tls` secret). TLS is terminated here — your app
receives plain HTTP and never handles TLS itself.

**HTTPRoute** (`charts/api/templates/httproute.yaml`) — routing rules for
HTTPS traffic. Matches `api.localhost` and forwards to the `api` Service.
Uses `sectionName: https` to attach only to the HTTPS listener, so it doesn't
conflict with the redirect route on port 80.

**HTTPRoute (redirect)** (`charts/api/templates/https-redirect-httproute.yaml`)
— attaches to the HTTP listener only and returns a 301 redirect to HTTPS.

**ReferenceGrant** (`charts/api/templates/referencegrant.yaml`) — the Gateway
is in `default` but reads the TLS secret from `api`. Kubernetes blocks
cross-namespace references by default; this resource explicitly permits it.

---

### TLS: cert-manager

cert-manager automates the full certificate lifecycle: requesting, issuing,
storing, and renewing.

**ClusterIssuer** (`charts/api/templates/clusterissuer.yaml`) — uses
`selfSigned`, so cert-manager generates a certificate signed by itself. This
is why browsers show a warning locally.

**Certificate** (`charts/api/templates/certificate.yaml`) — declares that you
want a certificate for `api.localhost` stored as Secret `api-tls` in the `api`
namespace. cert-manager handles the rest.

> **Local only: `selfSigned`.** In production use an ACME issuer (Let's
> Encrypt) or your cloud provider's certificate service. The `Certificate`
> resource stays the same — only the `ClusterIssuer` type changes.

---

## Project Structure

```
.
├── charts/
│   ├── api/            # Application chart: Deployment, Service, Gateway, TLS, Routes
│   └── infra/          # Platform chart: GatewayClass, EnvoyProxy
├── kind-cluster/
│   └── kind.yaml       # KIND cluster config (port mappings)
├── src/                # Node.js application source
│   ├── server.js
│   └── package.json
├── Dockerfile
└── Makefile
```

---

## Adapting for Your Own App

1. **Replace `src/`** with your application code and update the `Dockerfile`
   if you're using a different runtime.

2. **Update the hostname** in `charts/api/values.yaml`:
   ```yaml
   hostname: myapp.localhost
   ```

3. **Rename the image** in `charts/api/values.yaml` and the `build`/`deploy`
   Makefile targets if you want something other than `api:dev`.

4. **Rename the namespace** in `charts/api/values.yaml` to match your app.

Everything else — the gateway, TLS, redirect, cross-namespace grant — works
without changes.

---

## Local vs Production

| | Local (this repo) | Production |
|---|---|---|
| Cluster | KIND (Docker container) | Managed k8s (GKE, EKS, AKS) |
| Ingress | `hostPort` + `extraPortMappings` | Cloud load balancer (`LoadBalancer` Service) |
| Image delivery | `kind load docker-image` | Container registry (ECR, GCR, Docker Hub) |
| `imagePullPolicy` | `Never` | `IfNotPresent` |
| TLS issuer | `selfSigned` | ACME / Let's Encrypt or cloud-managed |
| DNS | `*.localhost` (OS resolves) | Real registered domain + DNS records |
| `EnvoyProxy` resource | Required (hostPort + ClusterIP override) | Not needed — delete it |

---

## What to Add Before Production

**Liveness probe** — the readiness probe is already configured on `/healthz`.
Add a liveness probe on a separate endpoint only if your app can get into a
stuck/deadlocked state without crashing — for most simple apps, Kubernetes
already restarts crashed processes automatically.

**Multiple replicas** — set `replicas: 2` (or more) in the Deployment so a
pod failure doesn't take down the app.

**Horizontal Pod Autoscaler** — scales replicas automatically based on
CPU/memory load.

**RBAC and Service Accounts** — explicit permissions for what each workload
can do inside the cluster.

**Image pull secrets** — credentials for pulling from a private registry,
configured on the Deployment or ServiceAccount.

**Real DNS** — register a domain, point it at the load balancer IP via your
DNS provider (Route 53, Cloud DNS, etc.).
