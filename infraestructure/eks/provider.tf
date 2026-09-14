terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
  }
}

provider "aws" {
  region = local.aws_region

  default_tags {
    tags = {
      Project   = "k8s-cloud-project"
      ManagedBy = "terraform"
      Layer     = "k8s"
    }
  }
}
