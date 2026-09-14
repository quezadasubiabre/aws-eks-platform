data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  aws_region   = "eu-west-1"
  vpc_cidr     = "10.0.0.0/16"
  cluster_name = "k8s-cloud-project"

  az_count = 3
  azs      = slice(data.aws_availability_zones.available.names, 0, local.az_count)

  public_subnet_cidrs  = [for i in range(local.az_count) : cidrsubnet(local.vpc_cidr, 4, i)]
  private_subnet_cidrs = [for i in range(local.az_count) : cidrsubnet(local.vpc_cidr, 4, i + local.az_count)]
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.cluster_name}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.cluster_name}-igw"
  }
}

# ---------------------------------------------------------------------------
# Subnets
# ---------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = local.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "${local.cluster_name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.private_subnet_cidrs[count.index]

  tags = {
    Name                                        = "${local.cluster_name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

# ---------------------------------------------------------------------------
# NAT gateway (single, shared across all private subnets — cheapest managed
# option). Not highly available: if its AZ goes down, private subnets lose
# internet egress until AWS recovers it or it's redeployed in another AZ.
# ---------------------------------------------------------------------------

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.cluster_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${local.cluster_name}-nat-gw"
  }

  depends_on = [aws_internet_gateway.this]
}

# ---------------------------------------------------------------------------
# Route tables
# ---------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${local.cluster_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count = local.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name = "${local.cluster_name}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count = local.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# SSM parameters (exposes network IDs to other layers, e.g. infraestructure/k8s)
# ---------------------------------------------------------------------------

resource "aws_ssm_parameter" "vpc_id" {
  name  = "/${local.cluster_name}/network/vpc-id"
  type  = "String"
  value = aws_vpc.this.id

  tags = {
    Name = "${local.cluster_name}-vpc-id"
  }
}

resource "aws_ssm_parameter" "public_subnet_ids" {
  name  = "/${local.cluster_name}/network/public-subnet-ids"
  type  = "StringList"
  value = join(",", aws_subnet.public[*].id)

  tags = {
    Name = "${local.cluster_name}-public-subnet-ids"
  }
}

resource "aws_ssm_parameter" "private_subnet_ids" {
  name  = "/${local.cluster_name}/network/private-subnet-ids"
  type  = "StringList"
  value = join(",", aws_subnet.private[*].id)

  tags = {
    Name = "${local.cluster_name}-private-subnet-ids"
  }
}
