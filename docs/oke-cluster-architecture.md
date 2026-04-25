# OKE Cluster Architecture

This document summarizes the current Oracle OKE cluster architecture managed by this repository.

## High-Level View

```mermaid
flowchart TD
    User[User Browser / Client]
    DNS[DNS Zone<br/>AWS Route 53]
    LB[OCI Network Load Balancer<br/>Service type=LoadBalancer]
    LE[Let's Encrypt ACME]
    Vault[OCI Vault]
    Git[GitHub repo<br/>waffle-world-oci]
    OCIR[Oracle Container Registry<br/>OCIR]

    subgraph OKE[OKE Cluster]
        GW[Istio Ingress Gateway<br/>namespace: istio-ingress]
        VS[Istio VirtualService Routing]
        Mesh[Istio Service Mesh]
        App1[Application Namespace<br/>waffledotcom-prod]
        App2[Application Namespace<br/>snutt-prod]
        App3[Application Namespace<br/>siksha-prod / others]
        Svc1[ClusterIP Service]
        Svc2[ClusterIP Service]
        Pod1[Deployment / Pods]
        Pod2[Deployment / Pods]
        Pod3[Stateful workloads / CronJobs]
        CM[cert-manager]
        ES[external-secrets]
        Argo[Argo CD]
        CA[OCI Cluster Autoscaler]
        NodePools[OKE Node Pools]
    end

    User --> DNS
    DNS --> LB
    LB --> GW
    GW --> VS
    VS --> Mesh
    Mesh --> App1
    Mesh --> App2
    Mesh --> App3
    App1 --> Svc1 --> Pod1
    App2 --> Svc2 --> Pod2
    App3 --> Pod3

    CM --> LE
    CM -. DNS-01 challenge .-> DNS
    CM --> GW

    ES --> Vault
    Vault -. synced secrets .-> App1
    Vault -. synced secrets .-> App2
    Vault -. synced secrets .-> App3

    Git --> Argo
    Argo --> GW
    Argo --> CM
    Argo --> ES
    Argo --> App1
    Argo --> App2
    Argo --> App3

    OCIR --> Pod1
    OCIR --> Pod2
    OCIR --> Pod3

    CA --> NodePools
    NodePools --> GW
    NodePools --> Mesh
    NodePools --> App1
    NodePools --> App2
    NodePools --> App3
```

## Traffic Flow

```mermaid
sequenceDiagram
    participant C as Client
    participant R53 as Route 53
    participant NLB as OCI NLB
    participant IG as Istio Ingress Gateway
    participant VS as VirtualService
    participant SVC as ClusterIP Service
    participant POD as App Pod

    C->>R53: Resolve *.wafflestudio.com
    R53-->>C: Public IP / record target
    C->>NLB: HTTPS request
    NLB->>IG: Forward to ingress gateway service
    IG->>VS: Match host / path
    VS->>SVC: Route to destination service
    SVC->>POD: Forward to app container
    POD-->>C: Response
```

## Control Plane and Supporting Components

```mermaid
flowchart LR
    Git[GitHub]
    Route53[AWS Route 53]
    LE[Let's Encrypt]
    OVault[OCI Vault]

    subgraph OKE[OKE Cluster]
        Argo[Argo CD]
        Apps[App Manifests]
        Infra[Infra Components]
        Cert[cert-manager]
        ESO[external-secrets]
        Autoscaler[OCI Cluster Autoscaler]
        Pools[OKE Node Pools]
    end

    Git --> Argo
    Argo --> Apps
    Argo --> Infra
    Infra --> Cert
    Infra --> ESO
    Infra --> Autoscaler
    Cert --> LE
    Cert --> Route53
    ESO --> OVault
    Autoscaler --> Pools
```

## Component Notes

- `Argo CD` is the deployment controller. The top-level application recursively loads `argocd/*/app.yaml` and continuously syncs the cluster from Git.
- `Istio` provides the service mesh and ingress layer. External traffic enters through the ingress gateway in `istio-ingress`.
- The ingress service is exposed with `Service type=LoadBalancer`, and OCI creates a `Network Load Balancer`.
- `VirtualService` resources map public hosts such as `argocd-oci.wafflestudio.com` or `wadot-api.wafflestudio.com` to internal services.
- `cert-manager` runs inside the cluster and issues TLS certificates using Let's Encrypt. DNS validation is done through AWS Route 53.
- `external-secrets` reads secrets from `OCI Vault` using Oracle-specific provider settings.
- Application pods pull images from `OCIR`.
- `cluster-autoscaler` is configured for OCI and scales OKE node pools.

## Observed Repository Mapping

- GitOps entrypoint: `argocd/top-level.yaml`
- Argo CD installation: `argocd/argocd/`
- Istio control plane: `argocd/istio/`
- Istio ingress gateway and public entrypoint: `argocd/istio-gateway/`
- cert-manager: `argocd/cert-manager/`
- External Secrets + OCI Vault integration: `argocd/external-secrets/`
- OCI cluster autoscaler: `argocd/cluster-autoscaler/`
- Example application namespaces: `argocd/waffledotcom-prod/`, `argocd/snutt-prod/`, `argocd/siksha-prod/`

## Important Detail About DNS

The repository shows a split responsibility:

- Public traffic enters the cluster through an OCI load balancer created from the Istio ingress service.
- TLS certificate issuance uses Route 53 for DNS-01 validation.
- Public DNS for `wafflestudio.com` is delegated to AWS Route 53, even though some services point to Oracle-owned IPs.

That means the architecture is not "AWS load balancer in front of the cluster". It is closer to:

- `AWS Route 53` for DNS hosting and ACME DNS validation
- `OCI Network Load Balancer` for cluster ingress
- `Istio` for L7 routing inside OKE

## Source Files

- [argocd/top-level.yaml](/Users/junby/Coding/waffle-world-oci/argocd/top-level.yaml)
- [argocd/istio-gateway/values.yaml](/Users/junby/Coding/waffle-world-oci/argocd/istio-gateway/values.yaml)
- [argocd/istio-gateway/resources.yaml](/Users/junby/Coding/waffle-world-oci/argocd/istio-gateway/resources.yaml)
- [argocd/cert-manager/resources.yaml](/Users/junby/Coding/waffle-world-oci/argocd/cert-manager/resources.yaml)
- [argocd/external-secrets/resources.yaml](/Users/junby/Coding/waffle-world-oci/argocd/external-secrets/resources.yaml)
- [argocd/cluster-autoscaler/values.yaml](/Users/junby/Coding/waffle-world-oci/argocd/cluster-autoscaler/values.yaml)
- [argocd/waffledotcom-prod/waffledotcom-server.yaml](/Users/junby/Coding/waffle-world-oci/argocd/waffledotcom-prod/waffledotcom-server.yaml)
