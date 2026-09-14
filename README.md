# aws-eks-platform

Terraform layers to provision a small AWS EKS cluster: a `static` networking layer (VPC, subnets, NAT gateway) and an `eks` layer (cluster, node groups, add-ons, IRSA roles).

## Prerequisites

- Terraform >= 1.5.0
- An AWS account and credentials configured (e.g. via `AWS_PROFILE` or environment variables)

## 1. Create static infra

```sh
terraform -chdir=infraestructure/static init
terraform -chdir=infraestructure/static apply
```

## 2. Create the EKS cluster

Copy the example variables file and set your own IAM user (this grants that user cluster-admin access via an EKS access entry):

```sh
cp infraestructure/eks/terraform.tfvars.example infraestructure/eks/terraform.tfvars
# edit infraestructure/eks/terraform.tfvars and set admin_iam_user
```

```sh
terraform -chdir=infraestructure/eks init
terraform -chdir=infraestructure/eks apply
```

The cluster takes about 12 minutes to create.

Configure kubectl to access the cluster:

```sh
aws eks update-kubeconfig --region eu-west-1 --name k8s-cloud-project
```

## Optional: remote state backend

By default, state is stored locally. To back it up in S3, add a `backend.tf` file in each layer (`infraestructure/static/` and `infraestructure/eks/`), replacing `bucket` and `region` with values for your own account:

```hcl
terraform {
  backend "s3" {
    bucket = "my-bucket"
    key    = "static/terraform.tfstate"
    region = "my-region"
  }
}
```
