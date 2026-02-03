# Cloudflare + AWS Integration - Main Terraform Configuration
# This demonstrates a production-ready multi-region setup with failover

terraform {
  required_version = ">= 1.5.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    bucket         = "your-terraform-state-bucket"
    key            = "cloudflare-aws-integration/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

# Primary AWS Provider (us-east-1)
provider "aws" {
  region = var.primary_region
  
  default_tags {
    tags = {
      Project     = "Cloudflare-AWS-Integration"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = var.owner_email
    }
  }
}

# Secondary AWS Provider (us-west-2) for failover
provider "aws" {
  alias  = "secondary"
  region = var.secondary_region
  
  default_tags {
    tags = {
      Project     = "Cloudflare-AWS-Integration"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = var.owner_email
      Region      = "Secondary"
    }
  }
}

# Cloudflare Provider
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Data source for Cloudflare zone
data "cloudflare_zone" "main" {
  name = var.domain_name
}

# ============================================
# PRIMARY REGION INFRASTRUCTURE
# ============================================

module "primary_vpc" {
  source = "./modules/vpc"
  
  region             = var.primary_region
  vpc_cidr           = var.primary_vpc_cidr
  availability_zones = var.primary_azs
  environment        = var.environment
  name_prefix        = "primary"
}

module "primary_alb" {
  source = "./modules/alb"
  
  vpc_id             = module.primary_vpc.vpc_id
  public_subnet_ids  = module.primary_vpc.public_subnet_ids
  environment        = var.environment
  name_prefix        = "primary"
  certificate_arn    = module.acm_primary.certificate_arn
  health_check_path  = var.health_check_path
}

module "primary_compute" {
  source = "./modules/compute"
  
  vpc_id                = module.primary_vpc.vpc_id
  private_subnet_ids    = module.primary_vpc.private_subnet_ids
  alb_target_group_arn  = module.primary_alb.target_group_arn
  alb_security_group_id = module.primary_alb.security_group_id
  environment           = var.environment
  instance_type         = var.instance_type
  min_size              = var.min_instances
  max_size              = var.max_instances
  desired_capacity      = var.desired_instances
}

module "primary_rds" {
  source = "./modules/rds"
  
  vpc_id                = module.primary_vpc.vpc_id
  private_subnet_ids    = module.primary_vpc.private_subnet_ids
  database_name         = var.database_name
  master_username       = var.db_master_username
  master_password       = var.db_master_password
  instance_class        = var.db_instance_class
  allocated_storage     = var.db_allocated_storage
  multi_az              = true
  backup_retention      = 7
  environment           = var.environment
  
  # Enable cross-region replication
  enable_cross_region_replica = true
  replica_region              = var.secondary_region
}

module "acm_primary" {
  source = "./modules/acm"
  
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  zone_id                   = data.cloudflare_zone.main.id
  environment               = var.environment
}

# ============================================
# SECONDARY REGION INFRASTRUCTURE (Failover)
# ============================================

module "secondary_vpc" {
  source = "./modules/vpc"
  
  providers = {
    aws = aws.secondary
  }
  
  region             = var.secondary_region
  vpc_cidr           = var.secondary_vpc_cidr
  availability_zones = var.secondary_azs
  environment        = var.environment
  name_prefix        = "secondary"
}

module "secondary_alb" {
  source = "./modules/alb"
  
  providers = {
    aws = aws.secondary
  }
  
  vpc_id             = module.secondary_vpc.vpc_id
  public_subnet_ids  = module.secondary_vpc.public_subnet_ids
  environment        = var.environment
  name_prefix        = "secondary"
  certificate_arn    = module.acm_secondary.certificate_arn
  health_check_path  = var.health_check_path
}

module "secondary_compute" {
  source = "./modules/compute"
  
  providers = {
    aws = aws.secondary
  }
  
  vpc_id                = module.secondary_vpc.vpc_id
  private_subnet_ids    = module.secondary_vpc.private_subnet_ids
  alb_target_group_arn  = module.secondary_alb.target_group_arn
  alb_security_group_id = module.secondary_alb.security_group_id
  environment           = var.environment
  instance_type         = var.instance_type
  min_size              = var.min_instances_secondary
  max_size              = var.max_instances_secondary
  desired_capacity      = var.desired_instances_secondary
}

module "acm_secondary" {
  source = "./modules/acm"
  
  providers = {
    aws = aws.secondary
  }
  
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  zone_id                   = data.cloudflare_zone.main.id
  environment               = var.environment
}

# ============================================
# CLOUDFLARE CONFIGURATION
# ============================================

# DNS Records
resource "cloudflare_record" "root" {
  zone_id = data.cloudflare_zone.main.id
  name    = "@"
  value   = cloudflare_load_balancer.main.id
  type    = "CNAME"
  proxied = true
  ttl     = 1 # Auto TTL when proxied
  
  comment = "Root domain pointing to Cloudflare Load Balancer"
}

resource "cloudflare_record" "www" {
  zone_id = data.cloudflare_zone.main.id
  name    = "www"
  value   = cloudflare_load_balancer.main.id
  type    = "CNAME"
  proxied = true
  ttl     = 1
  
  comment = "WWW subdomain pointing to Cloudflare Load Balancer"
}

resource "cloudflare_record" "api" {
  zone_id = data.cloudflare_zone.main.id
  name    = "api"
  value   = cloudflare_load_balancer.main.id
  type    = "CNAME"
  proxied = true
  ttl     = 1
  
  comment = "API subdomain pointing to Cloudflare Load Balancer"
}

# Load Balancer Monitors (Health Checks)
resource "cloudflare_load_balancer_monitor" "primary" {
  type        = "https"
  description = "Primary region health check"
  method      = "GET"
  path        = var.health_check_path
  interval    = 30
  timeout     = 10
  retries     = 2
  
  expected_codes = "200"
  expected_body  = "healthy"
  
  header {
    header = "Host"
    values = [var.domain_name]
  }
  
  allow_insecure   = false
  follow_redirects = false
}

resource "cloudflare_load_balancer_monitor" "secondary" {
  type        = "https"
  description = "Secondary region health check"
  method      = "GET"
  path        = var.health_check_path
  interval    = 30
  timeout     = 10
  retries     = 2
  
  expected_codes = "200"
  expected_body  = "healthy"
  
  header {
    header = "Host"
    values = [var.domain_name]
  }
  
  allow_insecure   = false
  follow_redirects = false
}

# Load Balancer Pools
resource "cloudflare_load_balancer_pool" "primary" {
  name        = "primary-pool-${var.environment}"
  description = "Primary region pool (us-east-1)"
  
  monitor = cloudflare_load_balancer_monitor.primary.id
  
  origins {
    name    = "primary-alb"
    address = module.primary_alb.dns_name
    enabled = true
    weight  = 1
  }
  
  enabled               = true
  minimum_origins       = 1
  notification_email    = var.notification_email
  check_regions         = ["WNAM", "ENAM"] # Western and Eastern North America
}

resource "cloudflare_load_balancer_pool" "secondary" {
  name        = "secondary-pool-${var.environment}"
  description = "Secondary region pool (us-west-2)"
  
  monitor = cloudflare_load_balancer_monitor.secondary.id
  
  origins {
    name    = "secondary-alb"
    address = module.secondary_alb.dns_name
    enabled = true
    weight  = 1
  }
  
  enabled               = true
  minimum_origins       = 1
  notification_email    = var.notification_email
  check_regions         = ["WNAM"]
}

# Cloudflare Load Balancer
resource "cloudflare_load_balancer" "main" {
  zone_id = data.cloudflare_zone.main.id
  name    = var.domain_name
  
  default_pool_ids = [
    cloudflare_load_balancer_pool.primary.id
  ]
  
  fallback_pool_id = cloudflare_load_balancer_pool.secondary.id
  
  description = "Multi-region load balancer with automatic failover"
  proxied     = true
  enabled     = true
  
  # Geo-steering (optional)
  region_pools {
    region   = "WNAM"
    pool_ids = [cloudflare_load_balancer_pool.primary.id]
  }
  
  region_pools {
    region   = "ENAM"
    pool_ids = [cloudflare_load_balancer_pool.primary.id]
  }
  
  # Steering policy
  steering_policy = "dynamic_latency"
  
  # Session affinity
  session_affinity = "cookie"
  session_affinity_ttl = 3600
}

# SSL/TLS Settings
resource "cloudflare_zone_settings_override" "main" {
  zone_id = data.cloudflare_zone.main.id
  
  settings {
    # SSL
    ssl                      = "full"
    always_use_https         = "on"
    min_tls_version          = "1.2"
    tls_1_3                  = "on"
    automatic_https_rewrites = "on"
    
    # Security
    security_level           = "medium"
    challenge_ttl            = 1800
    browser_check            = "on"
    hotlink_protection       = "on"
    
    # Performance
    brotli                   = "on"
    early_hints              = "on"
    http2                    = "on"
    http3                    = "on"
    zero_rtt                 = "on"
    
    # Caching
    cache_level              = "aggressive"
    
    # DDoS
    browser_cache_ttl        = 14400
  }
}

# WAF Rules
resource "cloudflare_ruleset" "waf" {
  zone_id     = data.cloudflare_zone.main.id
  name        = "WAF Rules for ${var.domain_name}"
  description = "Custom WAF rules for application protection"
  kind        = "zone"
  phase       = "http_request_firewall_custom"
  
  # Block SQL Injection attempts
  rules {
    action      = "block"
    description = "Block SQL Injection attempts"
    enabled     = true
    
    expression = "(http.request.uri.query contains \"union\" and http.request.uri.query contains \"select\") or (http.request.uri.query contains \"' or '1'='1\")"
  }
  
  # Rate limiting for API endpoints
  rules {
    action      = "challenge"
    description = "Rate limit API endpoints"
    enabled     = true
    
    expression = "(http.request.uri.path contains \"/api/\") and (rate(5m) > 100)"
  }
  
  # Block known bad user agents
  rules {
    action      = "block"
    description = "Block malicious user agents"
    enabled     = true
    
    expression = "(http.user_agent contains \"sqlmap\") or (http.user_agent contains \"nikto\") or (http.user_agent contains \"nmap\")"
  }
}

# Page Rules for Performance
resource "cloudflare_page_rule" "cache_static" {
  zone_id  = data.cloudflare_zone.main.id
  target   = "${var.domain_name}/static/*"
  priority = 1
  
  actions {
    cache_level         = "cache_everything"
    edge_cache_ttl      = 86400
    browser_cache_ttl   = 86400
  }
}

resource "cloudflare_page_rule" "cache_api" {
  zone_id  = data.cloudflare_zone.main.id
  target   = "${var.domain_name}/api/*"
  priority = 2
  
  actions {
    cache_level = "bypass"
  }
}

# Rate Limiting
resource "cloudflare_rate_limit" "login" {
  zone_id   = data.cloudflare_zone.main.id
  threshold = 5
  period    = 60
  
  match {
    request {
      url_pattern = "${var.domain_name}/login"
    }
  }
  
  action {
    mode    = "challenge"
    timeout = 3600
  }
  
  description = "Rate limit login attempts"
}

# ============================================
# MONITORING & ALERTS
# ============================================

# CloudWatch Alarms for Primary Region
resource "aws_cloudwatch_metric_alarm" "primary_alb_unhealthy" {
  alarm_name          = "primary-alb-unhealthy-targets"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Average"
  threshold           = "1"
  alarm_description   = "Alert when primary ALB has no healthy targets"
  
  dimensions = {
    LoadBalancer = module.primary_alb.arn_suffix
  }
  
  alarm_actions = [aws_sns_topic.alerts.arn]
}

# SNS Topic for Alerts
resource "aws_sns_topic" "alerts" {
  name = "cloudflare-aws-integration-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# ============================================
# OUTPUTS
# ============================================

output "cloudflare_load_balancer_id" {
  description = "Cloudflare Load Balancer ID"
  value       = cloudflare_load_balancer.main.id
}

output "primary_alb_dns" {
  description = "Primary ALB DNS name"
  value       = module.primary_alb.dns_name
}

output "secondary_alb_dns" {
  description = "Secondary ALB DNS name"
  value       = module.secondary_alb.dns_name
}

output "domain_name" {
  description = "Domain name configured"
  value       = var.domain_name
}

output "primary_region" {
  description = "Primary AWS region"
  value       = var.primary_region
}

output "secondary_region" {
  description = "Secondary AWS region"
  value       = var.secondary_region
}
