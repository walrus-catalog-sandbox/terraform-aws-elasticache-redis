locals {
  port = 6379

  hosts = [
    var.infrastructure.domain_suffix == null ?
    format("%s", aws_elasticache_replication_group.default.primary_endpoint_address) :
    format("%s.%s", aws_service_discovery_service.primary[0].name, var.infrastructure.domain_suffix)
  ]
  hosts_readonly = local.architecture == "replication" ? [
    var.infrastructure.domain_suffix == null ?
    format("%s", aws_elasticache_replication_group.default.reader_endpoint_address) :
    format("%s.%s", aws_service_discovery_service.reader[0].name, var.infrastructure.domain_suffix)
  ] : []

  endpoints = flatten([
    for c in local.hosts : format("%s:%d", c, local.port)
  ])
  endpoints_readonly = flatten([
    for c in(local.hosts_readonly != null ? local.hosts_readonly : []) : format("%s:%d", c, local.port)
  ])
}

#
# Orchestration
#

output "context" {
  description = "The input context, a map, which is used for orchestration."
  value       = var.context
}

output "refer" {
  description = "The refer, a map, including hosts, ports and account, which is used for dependencies or collaborations."
  sensitive   = true
  value = {
    schema = "aws:elasticache:redis"
    params = {
      selector       = local.tags
      hosts          = local.hosts
      hosts_readonly = local.hosts_readonly
      port           = local.port
      password       = nonsensitive(local.password)
    }
  }
}

#
# Reference
#

output "connection" {
  description = "The connection, a string combined host and port, might be a comma separated string or a single string."
  value       = join(",", local.endpoints)
}

output "connection_without_port" {
  description = "The connection without port, a string combined host, might be a comma separated string or a single string."
  value       = join(",", local.hosts)
}

output "connection_readonly" {
  description = "The readonly connection, a string combined host and port, might be a comma separated string or a single string."
  value       = join(",", local.endpoints_readonly)
}

output "connection_without_port_readonly" {
  description = "The readonly connection without port, a string combined host, might be a comma separated string or a single string."
  value       = join(",", local.hosts_readonly)
}

output "password" {
  value       = local.password
  description = "The password of the account to access the service."
  sensitive   = true
}

## UI display

output "endpoints" {
  description = "The endpoints, a list of string combined host and port."
  value       = local.endpoints
}

output "endpoints_readonly" {
  description = "The readonly endpoints, a list of string combined host and port."
  value       = local.endpoints_readonly
}
