locals {
  aws_region      = "eu-west-1"
  cluster_name    = "k8s-cloud-project"
  cluster_version = "1.36"

  tags = {
    Layer = "eks"
  }
}

data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "vpc_id" {
  name = "/${local.cluster_name}/network/vpc-id"
}

data "aws_ssm_parameter" "private_subnet_ids" {
  name = "/${local.cluster_name}/network/private-subnet-ids"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = local.cluster_name
  cluster_version = local.cluster_version

  vpc_id     = data.aws_ssm_parameter.vpc_id.value
  subnet_ids = split(",", data.aws_ssm_parameter.private_subnet_ids.value)

  enable_irsa = true # registers the OIDC provider — this is what modules/irsa/ depends on

  cluster_endpoint_public_access = true # fine for a portfolio cluster; restrict for real prod

  # encrypt Kubernetes Secrets at rest using the AWS-managed default EKS key
  cluster_encryption_config = {
    resources        = ["secrets"]
    provider_key_arn = "alias/aws/eks"
  }

  # coredns is installed separately, after the node group is up (see aws_eks_addon.coredns below) —
  # installing it here makes the module wait on pod scheduling before nodes exist, which stalls the apply
  cluster_addons = {
    kube-proxy = { most_recent = true }

    # prefix delegation: assigns each ENI a /28 (16 IPs) in one allocation
    # instead of one secondary IP at a time, multiplying max-pods-per-node
    # on the same instance type. Needed because t3.medium's default IP-based
    # limit (17 pods) is too low even for this small a cluster.
    vpc-cni = {
      most_recent = true
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
  }

  # small baseline node group for system pods (CoreDNS, controllers, Argo CD itself)
  # GPU nodes for vLLM come later via Karpenter, not here
  eks_managed_node_groups = {
    system = {
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 1
      desired_size   = 1
      labels         = { role = "system" }

      # module defaults `platform` (and thus user-data rendering) to AL2's
      # bootstrap.sh path unless ami_type says otherwise — even though the
      # node actually boots AL2023. Without this, cloudinit_pre_nodeadm below
      # is silently dropped because the module thinks it's building an AL2 node.
      ami_type = "AL2023_x86_64_STANDARD"

      # raise kubelet's pod ceiling to match prefix-delegation capacity —
      # without this override, kubelet keeps the old IP-per-secondary-address
      # max-pods value (17) even though the CNI can now support far more.
      # AL2023 nodes boot via nodeadm, not bootstrap.sh, so the override has
      # to go in as a NodeConfig snippet (cloudinit_pre_nodeadm), not
      # bootstrap_extra_args (which AL2023's nodeadm silently ignores).
      cloudinit_pre_nodeadm = [
        {
          content_type = "application/node.eks.aws"
          content      = <<-EOT
            apiVersion: node.eks.aws/v1alpha1
            kind: NodeConfig
            spec:
              kubelet:
                config:
                  maxPods: 110
          EOT
        }
      ]
    }
  }

  # tag so Karpenter can auto-discover this cluster's node security group later
  node_security_group_tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }

  # control plane -> node rules the module doesn't open by default:
  # metrics-server's webhook listens on 10251 and the API server calls it directly
  # for `kubectl top` / HPA, so it needs an explicit hole in the node SG
  node_security_group_additional_rules = {
    ingress_cluster_metrics_server = {
      description                   = "Cluster API to node metrics-server webhook"
      protocol                      = "tcp"
      from_port                     = 10251
      to_port                       = 10251
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  # grant cluster admin to the IAM user running terraform/kubectl day-to-day —
  # without this, only the identity that first created the cluster gets access
  access_entries = {
    admin_user = {
      principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${var.admin_iam_user}"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  tags = local.tags
}

# single-GPU Spot node group for vLLM, defined outside eks_managed_node_groups
# on purpose: the module's eks-managed-node-group submodule hardcodes
# `lifecycle { ignore_changes = [scaling_config[0].desired_size] }`, so once
# created, desired_size can never be changed again through the module —
# `terraform apply -var gpu_desired_size=1` would silently no-op forever.
# Managing the node group directly here keeps desired_size mutable.
resource "aws_iam_role" "gpu_node" {
  name               = "${local.cluster_name}-gpu-node"
  assume_role_policy = data.aws_iam_policy_document.gpu_node_assume_role.json
}

data "aws_iam_policy_document" "gpu_node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "gpu_node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
  ])

  policy_arn = each.value
  role       = aws_iam_role.gpu_node.name
}

# raise kubelet's pod ceiling to match prefix-delegation capacity (see vpc-cni
# config above) — AL2023 nodes boot via nodeadm, so this must be delivered as
# a NodeConfig cloudinit part, not bootstrap_extra_args.
data "cloudinit_config" "gpu_node" {
  base64_encode = true
  gzip          = false
  boundary      = "MIMEBOUNDARY"

  part {
    content_type = "application/node.eks.aws"
    content      = <<-EOT
      apiVersion: node.eks.aws/v1alpha1
      kind: NodeConfig
      spec:
        kubelet:
          config:
            maxPods: 110
    EOT
  }
}

# EKS-managed node groups without a custom launch template get their own
# default security group instead of the cluster's shared node SG — that would
# cut this node off from the ingress/egress rules module.eks defines (e.g.
# the metrics-server webhook rule) and the Karpenter-discovery tag. Pin it to
# the same SG the module's own node groups use.
resource "aws_launch_template" "gpu_node" {
  name_prefix = "${local.cluster_name}-gpu-"

  vpc_security_group_ids = [module.eks.node_security_group_id]

  # EKS auto-merges its own cluster-join bootstrap data with this for AL2023
  # managed node groups, so only the maxPods override needs to be supplied.
  user_data = data.cloudinit_config.gpu_node.rendered

  # the AMI's default root volume (~20GB) isn't enough: the vllm-openai image
  # alone is ~11GB compressed and expands much larger once unpacked (full
  # CUDA toolkit, static libs) — was hitting DiskPressure/no-space-left mid
  # image-pull. Model weights live on the separate PVC (gitops/apps/vlmm),
  # this is just for the OS + container images/layers.
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${local.cluster_name}-gpu" })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eks_node_group" "gpu" {
  count           = var.gpu_desired_size
  cluster_name    = module.eks.cluster_name
  node_group_name = "ai-node"
  node_role_arn   = aws_iam_role.gpu_node.arn
  subnet_ids      = split(",", data.aws_ssm_parameter.private_subnet_ids.value)

  ami_type      = "AL2023_x86_64_NVIDIA" # ships NVIDIA driver + container runtime preinstalled
  capacity_type = "SPOT"
  # multiple instance types widen the Spot capacity pool EKS can draw from,
  # so a launch is less likely to fail when g5.xlarge is unavailable.
  # g4dn.xlarge is a smaller/older GPU (T4, 16GB VRAM vs g5's A10G, 24GB) —
  # fine for testing/smaller models, but re-check vLLM sizing if it lands there.
  instance_types = ["g5.xlarge", "g4dn.xlarge"]
  version        = module.eks.cluster_version

  launch_template {
    id      = aws_launch_template.gpu_node.id
    version = aws_launch_template.gpu_node.latest_version
  }

  # desired_size defaults to 0 (see var.gpu_desired_size) — scale to 1 only
  # while actively testing, then back to 0, since Spot g5.xlarge still runs
  # ~$0.30-0.45/hr in eu-west-1.
  scaling_config {
    min_size     = 0
    max_size     = 1
    desired_size = var.gpu_desired_size
  }

  labels = { role = "gpu" }

  # keep regular pods (Argo CD, monitoring, etc.) off the expensive GPU
  # node — only pods that explicitly tolerate this taint (vLLM's
  # Deployment) will be scheduled here
  taint {
    key    = "nvidia.com/gpu"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  depends_on = [
    aws_iam_role_policy_attachment.gpu_node,
  ]

  tags = local.tags
}

data "aws_eks_addon_version" "coredns" {
  addon_name         = "coredns"
  kubernetes_version = module.eks.cluster_version
  most_recent        = true
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "coredns"
  addon_version               = data.aws_eks_addon_version.coredns.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # node group must be Ready before coredns pods can schedule
  depends_on = [module.eks.eks_managed_node_groups]
}

data "aws_eks_addon_version" "metrics_server" {
  addon_name         = "metrics-server"
  kubernetes_version = module.eks.cluster_version
  most_recent        = true
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "metrics-server"
  addon_version               = data.aws_eks_addon_version.metrics_server.version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # single replica: this is a 1-node cluster, so the default 2 replicas just
  # burn pod-IP slots (17 max on t3.medium) with no HA benefit
  configuration_values = jsonencode({
    replicas = 1
  })

  # node group must be Ready before metrics-server pods can schedule
  depends_on = [module.eks.eks_managed_node_groups]
}

data "aws_eks_addon_version" "ebs_csi_driver" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = module.eks.cluster_version
  most_recent        = true
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = data.aws_eks_addon_version.ebs_csi_driver.version
  service_account_role_arn    = aws_iam_role.ebs_csi_driver.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # single replica for the controller: this is a 1-node cluster, so the
  # default 2 replicas just burn pod-IP slots (17 max on t3.medium) with no
  # HA benefit. ebs-csi-node is a DaemonSet (1 per node already, unaffected).
  configuration_values = jsonencode({
    controller = {
      replicaCount = 1
    }
  })

  # node group must be Ready before ebs-csi-node pods can schedule
  depends_on = [module.eks.eks_managed_node_groups]
}

resource "aws_iam_role" "ebs_csi_driver" {
  name               = "${local.cluster_name}-ebs-csi-driver"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_driver_assume_role.json
}

data "aws_iam_policy_document" "ebs_csi_driver_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_driver.name
}

