# Changelog

## Unreleased

- Initial 3-tier VPC for dev environment
  - VPC `10.10.0.0/16` across 3 AZs
  - Public, private, and database subnet tiers
  - Single shared NAT Gateway (dev cost optimization)
  - DB subnet group + ElastiCache subnet group
