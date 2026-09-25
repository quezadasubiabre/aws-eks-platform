# aws-eks-platform

Terraform layers to provision a small AWS EKS cluster, plus a GitOps setup (Argo CD) to install Argo CD itself, a monitoring stack, and a networking chain (AWS Load Balancer Controller + cert-manager + Traefik) exposing an app over HTTPS. Every step below is a `make` target — see the [Makefile](Makefile) for the underlying commands.

## Prerequisites

- Terraform >= 1.5.0
- `kubectl`, `aws` CLI, and AWS credentials configured under a profile named `myaws` (or edit `AWS_PROFILE` in the Makefile)
- A domain managed through Cloudflare, and a Cloudflare API token (Zone:DNS:Edit) stored in AWS SSM Parameter Store at `/k8s-cloud-project/cert-manager/cloudflare-api-token` — only needed for the networking section

## 1. Create static infra

```sh
make deploy-infra
```

Provisions the VPC, subnets, and NAT gateway (`infraestructure/static`).

## 2. Create the EKS cluster

Copy the example variables file and set your own IAM user (this grants that user cluster-admin access via an EKS access entry):

```sh
cp infraestructure/eks/terraform.tfvars.example infraestructure/eks/terraform.tfvars
# edit infraestructure/eks/terraform.tfvars and set admin_iam_user
```

```sh
make deploy-eks
```

The cluster takes about 12 minutes to create.

```sh
make eks-login
```

Configures `kubectl` to point at the new cluster.

## 3. Install Argo CD

```sh
make install-argocd
```

Installs Argo CD into the `argocd` namespace and disables Dex (no external identity provider is configured; log in with the built-in `admin` account instead).

```sh
make open-argocd
```

Prints the initial admin password and port-forwards the UI to `https://localhost:8080`.

Argo CD also needs read access to this Git repo to sync Applications from it:

```sh
export GITHUB_USERNAME=<your-github-username>
export GITHUB_TOKEN=<a-github-token-with-repo-read-access>
make add-argocd-credentials
```

## 4. Networking (Load Balancer Controller, cert-manager, Traefik)

Exposes a Service to the internet over HTTPS: the AWS Load Balancer Controller provisions an NLB, cert-manager issues a TLS certificate via Let's Encrypt (DNS-01 challenge through Cloudflare), and Traefik terminates TLS and routes traffic inside the cluster.

```sh
export ACME_EMAIL=<your-email-for-lets-encrypt>
make install-app
```

This pulls the Cloudflare API token from SSM into a Secret, then installs the Load Balancer Controller, cert-manager, the `ClusterIssuer`, and Traefik, in that order.

Traefik's load balancer is restricted to your own IP by default. Keep it in sync with:

```sh
make update-my-ip
```

After Traefik is up, point your domain's DNS (a CNAME record, in Cloudflare) at the NLB hostname shown under `kubectl get ingress` — this is a manual step, since the NLB gets a new hostname whenever it's recreated.

## 5. Monitoring (Prometheus, Grafana, Loki)

```sh
kubectl apply -f gitops/bootstrap/storage-class-app.yaml
kubectl apply -f gitops/bootstrap/monitoring-app.yaml
kubectl apply -f gitops/bootstrap/loki-app.yaml
```

```sh
make open-graphana
```

Port-forwards Grafana to `http://localhost:3000` (default login: `admin` / `admin`, set in `gitops/apps/monitoring/values.yaml` — change it after first login).

## 6. Example app: static site

```sh
kubectl apply -f gitops/bootstrap/static-site-app.yaml
```

Deploys [`dockersamples/static-site`](https://hub.docker.com/r/dockersamples/static-site) behind Traefik, to confirm the NLB → Traefik → cert-manager chain works end to end.

## 7. GPU workload (vLLM)

The cluster's GPU node group is scaled to 0 by default (Spot `g5.xlarge`/`g4dn.xlarge` cost money even idle). To run something on it:

```sh
make gpu-node
```

Scales the GPU node group to 1 (`gpu_desired_size = 1` in `infraestructure/eks`). Scale it back to 0 the same way when you're done, to stop paying for it.

```sh
kubectl apply -f gitops/bootstrap/nvidia-gpu-app.yaml
```

Installs the NVIDIA device plugin and dcgm-exporter, so the GPU node's `nvidia.com/gpu` resource is schedulable and its metrics are scraped by Prometheus.

```sh
make install-llm
```

Deploys vLLM (`gitops/bootstrap/vllm.yaml`), serving an OpenAI-compatible API behind Traefik.

## Optional: remote state backend

By default, Terraform state is stored locally. To back it up in S3, add a `backend.tf` file in each layer (`infraestructure/static/` and `infraestructure/eks/`), replacing `bucket` and `region` with values for your own account:

```hcl
terraform {
  backend "s3" {
    bucket = "my-bucket"
    key    = "static/terraform.tfstate"
    region = "my-region"
  }
}
```
