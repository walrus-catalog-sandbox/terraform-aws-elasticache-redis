terraform {
  required_version = ">= 1.0"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.1"
    }
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.24.0"
    }
  }
}

provider "aws" {}

data "aws_availability_zones" "selected" {
  state = "available"

  lifecycle {
    postcondition {
      condition     = length(self.names) > 0
      error_message = "Failed to get Avaialbe Zones"
    }
  }
}

# create vpc.

resource "aws_vpc" "example" {
  instance_tenancy     = "default"
  enable_dns_hostnames = true
  enable_dns_support   = true
  cidr_block           = "10.0.0.0/16"
}

resource "aws_subnet" "example" {
  for_each = {
    for k, v in data.aws_availability_zones.selected.names : v => cidrsubnet(aws_vpc.example.cidr_block, 8, k)
  }

  vpc_id            = aws_vpc.example.id
  availability_zone = each.key
  cidr_block        = each.value
}

#resource "aws_internet_gateway" "example" {
#  vpc_id = aws_vpc.example.id
#}
#
#resource "aws_route" "example" {
#  destination_cidr_block = "0.0.0.0/0"
#  route_table_id         = aws_vpc.example.default_route_table_id
#  gateway_id             = aws_internet_gateway.example.id
#}

# create private dns.

resource "aws_service_discovery_private_dns_namespace" "example" {
  name = "example-dev-dns"
  vpc  = aws_vpc.example.id
}

# create mysql service.

module "this" {
  source = "../.."

  infrastructure = {
    vpc_id        = aws_vpc.example.id
    domain_suffix = aws_service_discovery_private_dns_namespace.example.name
  }

  architecture                  = "replication"
  replication_readonly_replicas = 3

  depends_on = [aws_service_discovery_private_dns_namespace.example]
}

output "context" {
  value = module.this.context
}

output "selector" {
  value = module.this.selector
}

output "endpoint_internal" {
  value = module.this.endpoint_internal
}

output "endpoint_internal_readonly" {
  value = module.this.endpoint_internal_readonly
}

output "password" {
  value = nonsensitive(module.this.password)
}