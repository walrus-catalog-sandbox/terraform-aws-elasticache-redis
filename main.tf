locals {
  project_name     = coalesce(try(var.context["project"]["name"], null), "default")
  project_id       = coalesce(try(var.context["project"]["id"], null), "default_id")
  environment_name = coalesce(try(var.context["environment"]["name"], null), "test")
  environment_id   = coalesce(try(var.context["environment"]["id"], null), "test_id")
  resource_name    = coalesce(try(var.context["resource"]["name"], null), "example")
  resource_id      = coalesce(try(var.context["resource"]["id"], null), "example_id")

  namespace = join("-", [local.project_name, local.environment_name])

  tags = {
    "Name" = join("-", [local.namespace, local.resource_name])

    "walrus.seal.io/catalog-name"     = "terraform-aws-elasticache-redis"
    "walrus.seal.io/project-id"       = local.project_id
    "walrus.seal.io/environment-id"   = local.environment_id
    "walrus.seal.io/resource-id"      = local.resource_id
    "walrus.seal.io/project-name"     = local.project_name
    "walrus.seal.io/environment-name" = local.environment_name
    "walrus.seal.io/resource-name"    = local.resource_name
  }

  architecture = coalesce(var.architecture, "standalone")
}

# create vpc.

resource "aws_vpc" "default" {
  count = var.infrastructure.vpc_id == null ? 1 : 0

  instance_tenancy     = "default"
  enable_dns_hostnames = true
  enable_dns_support   = true
  cidr_block           = "10.0.0.0/16"
}


data "aws_availability_zones" "selected" {
  count = var.infrastructure.vpc_id == null ? 1 : 0

  state = "available"

  lifecycle {
    postcondition {
      condition     = length(self.names) > 0
      error_message = "Failed to get Avaialbe Zones"
    }
  }
}

resource "aws_subnet" "default" {
  for_each = var.infrastructure.vpc_id == null ? {
    for k, v in data.aws_availability_zones.selected[0].names : v => cidrsubnet(aws_vpc.default[0].cidr_block, 8, k)
  } : {}

  vpc_id            = aws_vpc.default[0].id
  availability_zone = each.key
  cidr_block        = each.value
}

#
# Ensure
#

data "aws_vpc" "selected" {
  id = var.infrastructure.vpc_id != null ? var.infrastructure.vpc_id : aws_vpc.default[0].id

  state = "available"

  lifecycle {
    postcondition {
      condition     = var.infrastructure.domain_suffix == null || (self.enable_dns_support && self.enable_dns_hostnames)
      error_message = "VPC needs to enable DNS support and DNS hostnames resolution"
    }
  }
}

data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }

  lifecycle {
    postcondition {
      condition     = local.architecture == "replication" ? length(self.ids) > 1 : length(self.ids) > 0
      error_message = "Replication mode needs multiple subnets"
    }
  }
}

data "aws_kms_key" "selected" {
  count = var.infrastructure.kms_key_id != null ? 1 : 0

  key_id = var.infrastructure.kms_key_id

  lifecycle {
    postcondition {
      condition     = self.enabled
      error_message = "KMS key needs to be enabled"
    }
  }
}

data "aws_service_discovery_dns_namespace" "selected" {
  count = var.infrastructure.domain_suffix != null ? 1 : 0

  name = var.infrastructure.domain_suffix
  type = "DNS_PRIVATE"
}

#
# Random
#

# create a random password for blank password input.

resource "random_password" "password" {
  length      = 16
  special     = false
  lower       = true
  min_lower   = 3
  min_upper   = 3
  min_numeric = 3
}

# create the name with a random suffix.

resource "random_string" "name_suffix" {
  length  = 10
  special = false
  upper   = false
}

locals {
  name        = join("-", [local.resource_name, random_string.name_suffix.result])
  fullname    = format("walrus-%s", md5(join("-", [local.namespace, local.name])))
  description = "Created by Walrus catalog, and provisioned by Terraform."
  password    = coalesce(var.password, random_password.password.result)

  replication_readonly_replicas = var.replication_readonly_replicas == 0 ? 1 : var.replication_readonly_replicas
}

#
# Deployment
#

# create parameters group.

locals {
  version = coalesce(var.engine_version == "6.0" ? "6.x" : var.engine_version, "7.0")
  version_family_map = {
    "6.x" = "redis6.x",
    "7.0" = "redis7",
  }
  parameters = merge(
    {
      "cluster-enabled" = "no"
    },
    {
      for c in(var.engine_parameters != null ? var.engine_parameters : []) : c.name => c.value
      if try(c.value != "", false)
    }
  )
}

resource "aws_elasticache_parameter_group" "target" {
  name        = local.fullname
  description = local.description
  tags        = local.tags

  family = local.version_family_map[local.version]

  dynamic "parameter" {
    for_each = try(nonsensitive(local.parameters), local.parameters)
    content {
      name  = parameter.key
      value = tostring(parameter.value)
    }
  }
}

# create subnet group

resource "aws_elasticache_subnet_group" "target" {
  name        = local.fullname
  description = local.description
  tags        = local.tags

  subnet_ids = data.aws_subnets.selected.ids
}

# create security group.

resource "aws_security_group" "target" {
  name        = local.fullname
  description = local.description
  tags        = local.tags

  vpc_id = data.aws_vpc.selected.id
}

resource "aws_security_group_rule" "target" {
  description = local.description

  security_group_id = aws_security_group.target.id
  type              = "ingress"
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.selected.cidr_block]
  from_port         = 6379
  to_port           = 6379
}

# create group.

resource "aws_elasticache_replication_group" "default" {
  description = local.description
  tags        = local.tags

  replication_group_id = local.fullname

  multi_az_enabled           = local.architecture == "replication"
  automatic_failover_enabled = local.architecture == "replication"
  subnet_group_name          = aws_elasticache_subnet_group.target.name
  security_group_ids         = [aws_security_group.target.id]

  num_cache_clusters = local.architecture == "replication" ? local.replication_readonly_replicas + 1 : 1

  engine               = "redis"
  engine_version       = local.version
  parameter_group_name = aws_elasticache_parameter_group.target.name
  auth_token           = local.password
  port                 = 6379

  node_type                  = try(var.resources.class, "cache.t2.micro")
  transit_encryption_enabled = true
  at_rest_encryption_enabled = try(data.aws_kms_key.selected[0].arn != null, true)
  kms_key_id                 = try(data.aws_kms_key.selected[0].arn, null)

  apply_immediately        = true
  snapshot_window          = "00:00-05:00"
  snapshot_retention_limit = 5
}

#
# Exposing
#

resource "aws_service_discovery_service" "primary" {
  count = var.infrastructure.domain_suffix != null ? 1 : 0

  name        = format("%s.%s", (local.architecture == "replication" ? join("-", [local.name, "primary"]) : local.name), local.namespace)
  description = local.description
  tags        = local.tags

  dns_config {
    namespace_id   = data.aws_service_discovery_dns_namespace.selected[0].id
    routing_policy = "WEIGHTED"
    dns_records {
      ttl  = 30
      type = "CNAME"
    }
  }

  force_destroy = true
}

resource "aws_service_discovery_instance" "primary" {
  count = var.infrastructure.domain_suffix != null ? 1 : 0

  instance_id = aws_elasticache_replication_group.default.id
  service_id  = aws_service_discovery_service.primary[0].id

  attributes = {
    AWS_INSTANCE_CNAME = aws_elasticache_replication_group.default.primary_endpoint_address
  }
}

resource "aws_service_discovery_service" "reader" {
  count = var.infrastructure.domain_suffix != null && local.architecture == "replication" ? 1 : 0

  name        = format("%s.%s", join("-", [local.name, "reader"]), local.namespace)
  description = local.description
  tags        = local.tags

  dns_config {
    namespace_id   = data.aws_service_discovery_dns_namespace.selected[0].id
    routing_policy = "WEIGHTED"
    dns_records {
      ttl  = 30
      type = "CNAME"
    }
  }

  force_destroy = true
}

resource "aws_service_discovery_instance" "reader" {
  count = var.infrastructure.domain_suffix != null && local.architecture == "replication" ? 1 : 0

  instance_id = aws_elasticache_replication_group.default.id
  service_id  = aws_service_discovery_service.reader[0].id

  attributes = {
    AWS_INSTANCE_CNAME = aws_elasticache_replication_group.default.reader_endpoint_address
  }
}
