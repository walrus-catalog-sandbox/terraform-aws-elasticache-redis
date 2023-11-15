locals {
  project_name     = coalesce(try(var.context["project"]["name"], null), "default")
  project_id       = coalesce(try(var.context["project"]["id"], null), "default_id")
  environment_name = coalesce(try(var.context["environment"]["name"], null), "test")
  environment_id   = coalesce(try(var.context["environment"]["id"], null), "test_id")
  resource_name    = coalesce(try(var.context["resource"]["name"], null), "example")
  resource_id      = coalesce(try(var.context["resource"]["id"], null), "example_id")

  namespace = join("-", [local.project_name, local.environment_name])
  tags = {
    "walrus.seal.io/project-id"       = local.project_id
    "walrus.seal.io/environment-id"   = local.environment_id
    "walrus.seal.io/resource-id"      = local.resource_id
    "walrus.seal.io/project-name"     = local.project_name
    "walrus.seal.io/environment-name" = local.environment_name
    "walrus.seal.io/resource-name"    = local.resource_name
  }
}

#
# Ensure
#

data "aws_vpc" "selected" {
  id = var.infrastructure.vpc_id

  state = "available"

  lifecycle {
    postcondition {
      condition     = self.enable_dns_support
      error_message = "VPC needs to enable DNS support"
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
      condition     = var.architecture == "replication" ? length(self.ids) > 1 : length(self.ids) > 0
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
  name     = join("-", [local.resource_name, random_string.name_suffix.result])
  fullname = join("-", [local.namespace, local.name])
  password = coalesce(var.password, random_password.password.result)
}

#
# Deployment
#

locals {
  version = coalesce(var.engine_version, "7.0")
  version_family_mapping = {
    "6.x" = "redis6.x",
    "7.0" = "redis7",
  }
}

# create security group.

resource "aws_security_group" "target" {
  name = local.fullname
  tags = local.tags

  vpc_id = data.aws_vpc.selected.id
}

resource "aws_security_group_rule" "target" {
  security_group_id = aws_security_group.target.id

  type        = "ingress"
  protocol    = "tcp"
  cidr_blocks = [data.aws_vpc.selected.cidr_block]
  from_port   = 6379
  to_port     = 6379
  description = "Access Redis from VPC"
}


resource "aws_elasticache_subnet_group" "target" {
  name        = local.fullname
  description = "Elasticache subnet group for ${local.fullname}"
  subnet_ids  = data.aws_subnets.selected.ids
  tags        = local.tags
}

resource "aws_elasticache_parameter_group" "target" {
  name        = local.fullname
  description = "Elasticache parameter group for ${local.fullname}"
  family      = local.version_family_mapping[local.version]

  dynamic "parameter" {
    for_each = concat([
      { name = "cluster-enabled", value = "no" }
    ], var.engine_parameters == null ? [] : var.engine_parameters)
    content {
      name  = parameter.value.name
      value = tostring(parameter.value.value)
    }
  }

  tags = local.tags

  # Ignore changes to the description since it will try to recreate the resource
  lifecycle {
    ignore_changes = [
      description,
    ]
  }
}

resource "aws_elasticache_replication_group" "default" {
  replication_group_id       = local.fullname
  description                = "Elasticache replication group for ${local.fullname}"
  tags                       = local.tags
  multi_az_enabled           = var.architecture == "replication"
  automatic_failover_enabled = var.architecture == "replication"
  subnet_group_name          = aws_elasticache_subnet_group.target.name
  security_group_ids         = [aws_security_group.target.id]

  num_cache_clusters = var.architecture == "replication" ? coalesce(var.replication_readonly_replicas, 1) + 1 : 1

  engine_version       = local.version
  parameter_group_name = aws_elasticache_parameter_group.target.name
  auth_token           = local.password
  port                 = 6379

  node_type                  = try(var.resources.node_type, "cache.t2.micro")
  transit_encryption_enabled = true
  at_rest_encryption_enabled = try(data.aws_kms_key.selected[0].arn != null, true)
  kms_key_id                 = try(data.aws_kms_key.selected[0].arn, null)
  snapshot_window            = "00:00-05:00"
  snapshot_retention_limit   = 5

  apply_immediately = true
}

resource "aws_service_discovery_service" "primary" {
  name = format("%s.%s", (var.architecture == "replication" ? join("-", [
    local.name, "primary"
  ]) : local.name), local.namespace)
  force_destroy = true

  dns_config {
    namespace_id   = data.aws_service_discovery_dns_namespace.selected.id
    routing_policy = "WEIGHTED"
    dns_records {
      ttl  = 10
      type = "CNAME"
    }
  }
}

resource "aws_service_discovery_instance" "primary" {
  instance_id = aws_elasticache_replication_group.default.id
  service_id  = aws_service_discovery_service.primary.id

  attributes = {
    AWS_INSTANCE_CNAME = aws_elasticache_replication_group.default.primary_endpoint_address
  }
}

resource "aws_service_discovery_service" "reader" {
  count = var.architecture == "replication" ? 1 : 0

  name          = format("%s.%s", join("-", [local.name, "reader"]), local.namespace)
  force_destroy = true

  dns_config {
    namespace_id   = data.aws_service_discovery_dns_namespace.selected.id
    routing_policy = "WEIGHTED"
    dns_records {
      ttl  = 10
      type = "CNAME"
    }
  }
}


resource "aws_service_discovery_instance" "reader" {
  count = var.architecture == "replication" ? 1 : 0

  instance_id = aws_elasticache_replication_group.default.id
  service_id  = aws_service_discovery_service.reader[0].id

  attributes = {
    AWS_INSTANCE_CNAME = aws_elasticache_replication_group.default.reader_endpoint_address
  }
}