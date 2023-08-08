terraform {
  backend "s3" {
    bucket         = "tfstate-hybrid-nw"
    key            = "hybrid-nw.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "tfstate-lock_hybrid-nw"
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 0.57"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

provider "awscc" {
  region = "us-east-1"
}

data "aws_region" "current" {}

locals {
  # ensure current provider region is an operating_regions entry
  all_ipam_regions = distinct(concat([data.aws_region.current.name], var.ipam_regions))
  # additional locals for tagging
  prefix = "${var.prefix}-${terraform.workspace}"
  common_tags = {
    Project     = var.project
    Environment = terraform.workspace
    Owner       = var.contact
    ManagedBy   = "Terraform"
  }
}

resource "aws_vpc_ipam" "main" {
  dynamic "operating_regions" {
    for_each = local.all_ipam_regions
    content {
      region_name = operating_regions.value
    }
  }
}

resource "aws_vpc_ipam_pool" "root" {
  address_family = "ipv4"
  ipam_scope_id  = aws_vpc_ipam.main.private_default_scope_id
  auto_import    = false
}

resource "aws_vpc_ipam_pool_cidr" "root_block" {
  ipam_pool_id = aws_vpc_ipam_pool.root.id
  cidr         = "10.0.0.0/8"
}

resource "aws_vpc_ipam_pool" "us-east-1" {
  address_family      = "ipv4"
  ipam_scope_id       = aws_vpc_ipam.main.private_default_scope_id
  description         = "us-east-1"
  locale              = "us-east-1"
  source_ipam_pool_id = aws_vpc_ipam_pool.root.id
}

resource "aws_vpc_ipam_pool" "us-west-1" {
  address_family      = "ipv4"
  ipam_scope_id       = aws_vpc_ipam.main.private_default_scope_id
  description         = "us-west-1"
  locale              = "us-west-1"
  source_ipam_pool_id = aws_vpc_ipam_pool.root.id
}

resource "aws_vpc_ipam_pool" "eu-west-2" {
  address_family      = "ipv4"
  ipam_scope_id       = aws_vpc_ipam.main.private_default_scope_id
  description         = "eu-west-2"
  locale              = "eu-west-2"
  source_ipam_pool_id = aws_vpc_ipam_pool.root.id
}

# In order to deprovision CIDRs all Allocations must be released. 
# Allocations created by a VPC take up to 30 minutes to be released.

resource "aws_vpc_ipam_pool_cidr" "us-east-1_block" {
  ipam_pool_id = aws_vpc_ipam_pool.us-east-1.id
  cidr         = "10.0.0.0/12"
}

resource "aws_vpc_ipam_pool_cidr" "us-west-1_block" {
  ipam_pool_id = aws_vpc_ipam_pool.us-west-1.id
  cidr         = "10.16.0.0/12"
}

resource "aws_vpc_ipam_pool_cidr" "eu-west-2_block" {
  ipam_pool_id = aws_vpc_ipam_pool.eu-west-2.id
  cidr         = "10.32.0.0/12"
}

module "California" {
  source     = "./us-west-1"
  pool_id    = aws_vpc_ipam_pool.us-west-1.id
  cidr_block = aws_vpc_ipam_pool_cidr.us-west-1_block
}

module "London" {
  source        = "./eu-west-2"
  pool_id       = aws_vpc_ipam_pool.eu-west-2.id
  cidr_block    = aws_vpc_ipam_pool_cidr.eu-west-2_block
  connection_id = aws_vpc_peering_connection.foo.id
}



resource "aws_vpc" "us-east-1_test" {
  ipv4_ipam_pool_id   = aws_vpc_ipam_pool.us-east-1.id
  ipv4_netmask_length = 28 // You can't assign anything smaller than 28. AWS reserves 5 in each VPC.
  depends_on = [
    aws_vpc_ipam_pool_cidr.us-east-1_block
  ]
}

resource "aws_vpc_peering_connection" "foo" {
  vpc_id      = aws_vpc.us-east-1_test.id
  peer_vpc_id = module.London.vpc-1_id
  peer_region = "eu-west-2"
  auto_accept = false // If both VPCs are not in the same AWS account and region do not enable the auto_accept attribute. The accepter can manage its side of the connection using the aws_vpc_peering_connection_accepter resource. 

  tags = {
    Side = "Requester"
  }
}

provider "aws" {
  alias  = "cal"
  region = "us-west-1"

  # Requester's credentials.
}

provider "aws" {
  alias  = "lon"
  region = "eu-west-2"

  # Accepter's credentials.
}

resource "aws_vpc_peering_connection" "foo2" {
  provider    = aws.cal
  vpc_id      = module.California.vpc-1_id
  peer_vpc_id = module.London.vpc-1_id
  peer_region = "eu-west-2"
  auto_accept = false // If both VPCs are not in the same AWS account and region do not enable the auto_accept attribute. The accepter can manage its side of the connection using the aws_vpc_peering_connection_accepter resource. 

  tags = {
    Side = "Requester"
  }
}

resource "aws_vpc_peering_connection_accepter" "bar2" {
  provider                  = aws.lon
  vpc_peering_connection_id = aws_vpc_peering_connection.foo2.id
  auto_accept               = true

  tags = {
    Side = "Accepter"
  }
}