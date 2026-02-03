# ============================================
# CLOUDFLARE + AWS INTEGRATION
# Production-Ready Multi-Region Setup with Automatic Failover
# ============================================
# 
# This Terraform configuration demonstrates:
# 1. Multi-region AWS infrastructure (Primary + Secondary)
# 2. Cloudflare integration with intelligent load balancing
# 3. Automatic failover in under 60 seconds
# 4. WAF security rules and DDoS protection
# 5. SSL/TLS encryption and performance optimization
#
# Author: Hadeed Ahmed
# ============================================

# ============================================
# SECTION 1: TERRAFORM CONFIGURATION
# ============================================
# This section defines which versions of Terraform and providers we're using

terraform {
  required_version = ">= 1.5.0"
  
  required_providers {
    # AWS Provider - for managing AWS resources
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    
    # Cloudflare Provider - for managing Cloudflare resources
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }

  # Remote state storage in S3 for team collaboration
  backend "s3" {
    bucket         = "your-terraform-state-bucket"
    key            = "cloudflare-aws-integration/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

# ============================================
# SECTION 2: PROVIDER CONFIGURATION
# ============================================
# We configure TWO AWS providers (primary + secondary regions) and ONE Cloudflare provider

# Primary AWS Provider - US-East-1 (Virginia)
# This is our main production region
provider "aws" {
  region = var.primary_region
  
  # These tags are automatically applied to all resources
  default_tags {
    tags = {
      Project     = "Cloudflare-AWS-Integration"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = var.owner_email
    }
  }
}

# Secondary AWS Provider - US-West-2 (Oregon)
# This is our failover/backup region
provider "aws" {
  alias  = "secondary"  # Alias allows us to use multiple AWS providers
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
# Manages DNS, CDN, WAF, and Load Balancing
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Get information about our Cloudflare zone (domain)
data "cloudflare_zone" "main" {
  name = var.domain_name
}

# ============================================
# SECTION 3: PRIMARY REGION INFRASTRUCTURE (US-EAST-1)
# ============================================
# This is our main production environment

# 3.1: VPC - Virtual Private Cloud
# Creates isolated network with public and private subnets across 3 availability zones
module "primary_vpc" {
  source = "./modules/vpc"
  
  region             = var.primary_region
  vpc_cidr           = var.primary_vpc_cidr        # Example: 10.0.0.0/16
  availability_zones = var.primary_azs             # Example: [us-east-1a, us-east-1b, us-east-1c]
  environment        = var.environment
  name_prefix        = "primary"
}

# 3.2: Application Load Balancer (ALB)
# Distributes incoming traffic across multiple servers
# Handles SSL termination and health checks
module "primary_alb" {
  source = "./modules/alb"
  
  vpc_id             = module.primary_vpc.vpc_id
  public_subnet_ids  = module.primary_vpc.public_subnet_ids
  environment        = var.environment
  name_prefix        = "primary"
  certificate_arn    = module.acm_primary.certificate_arn
  health_check_path  = var.health_check_path        # Example: /health
}

# 3.3: Compute Resources (EC2 Auto Scaling Group)
# Automatically scales servers up/down based on demand
module "primary_compute" {
  source = "./modules/compute"
  
  vpc_id                = module.primary_vpc.vpc_id
  private_subnet_ids    = module.primary_vpc.private_subnet_ids
  alb_target_group_arn  = module.primary_alb.target_group_arn
  alb_security_group_id = module.primary_alb.security_group_id
  environment           = var.environment
  instance_type         = var.instance_type         # Example: t3.medium
  min_size              = var.min_instances         # Minimum 2 instances
  max_size              = var.max_instances         # Maximum 10 instances
  desired_capacity      = var.desired_instances     # Start with 3 instances
}

# 3.4: RDS Database (PostgreSQL/MySQL)
# Multi-AZ deployment for high availability
# Automatic backups and cross-region replication enabled
module "primary_rds" {
  source = "./modules/rds"
  
  vpc_id                = module.primary_vpc.vpc_id
  private_subnet_ids    = module.primary_vpc.private_subnet_ids
  database_name         = var.database_name
  master_username       = var.db_master_username
  master_password       = var.db_master_password
  instance_class        = var.db_instance_class     # Example: db.t3.medium
  allocated_storage     = var.db_allocated_storage  # Example: 100 GB
  multi_az              = true                      # High availability within region
  backup_retention      = 7                         # Keep backups for 7 days
  environment           = var.environment
  
  # IMPORTANT: Cross-region replication for disaster recovery
  enable_cross_region_replica = true
  replica_region              = var.secondary_region
}

# 3.5: SSL/TLS Certificate (AWS Certificate Manager)
# Free SSL certificates from AWS, automatically renewed
module "acm_primary" {
  source = "./modules/acm"
  
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]  # Wildcard for subdomains
  zone_id                   = data.cloudflare_zone.main.id
  environment               = var.environment
}

# ============================================
# SECTION 4: SECONDARY REGION INFRASTRUCTURE (US-WEST-2)
# ============================================
# This is our failover/backup environment
# Identical architecture to primary but with reduced capacity for cost optimization

# 4.1: Secondary VPC
module "secondary_vpc" {
  source = "./modules/vpc"
  
  providers = {
    aws = aws.secondary  # Use the secondary AWS provider
  }
  
  region             = var.secondary_region
  vpc_cidr           = var.secondary_vpc_cidr       # Example: 10.1.0.0/16
  availability_zones = var.secondary_azs
  environment        = var.environment
  name_prefix        = "secondary"
}

# 4.2: Secondary Application Load Balancer
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

# 4.3: Secondary Compute (Reduced Capacity)
# Runs at lower capacity until failover is needed
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
  min_size              = var.min_instances_secondary     # Lower minimum
  max_size              = var.max_instances_secondary     # Can scale up if needed
  desired_capacity      = var.desired_instances_secondary # Start with fewer instances
}

# 4.4: Secondary SSL Certificate
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
# SECTION 5: CLOUDFLARE DNS CONFIGURATION
# ============================================
# DNS records that point to our Cloudflare Load Balancer

# Root domain (example.com)
resource "cloudflare_record" "root" {
  zone_id = data.cloudflare_zone.main.id
  name    = "@"
  value   = cloudflare_load_balancer.main.id
  type    = "CNAME"
  proxied = true  # Traffic goes through Cloudflare's CDN and security
  ttl     = 1     # Auto TTL when proxied
  
  comment = "Root domain pointing to Cloudflare Load Balancer"
}

# WWW subdomain (www.example.com)
resource "cloudflare_record" "www" {
  zone_id = data.cloudflare_zone.main.id
  name    = "www"
  value   = cloudflare_load_balancer.main.id
  type    = "CNAME"
  proxied = true
  ttl     = 1
  
  comment = "WWW subdomain pointing to Cloudflare Load Balancer"
}

# API subdomain (api.example.com)
resource "cloudflare_record" "api" {
  zone_id = data.cloudflare_zone.main.id
  name    = "api"
  value   = cloudflare_load_balancer.main.id
  type    = "CNAME"
  proxied = true
  ttl     = 1
  
  comment = "API subdomain pointing to Cloudflare Load Balancer"
}

# ============================================
# SECTION 6: CLOUDFLARE LOAD BALANCER - HEALTH MONITORS
# ============================================
# These health checks run every 30 seconds to verify each region is healthy

# Primary Region Health Monitor
resource "cloudflare_load_balancer_monitor" "primary" {
  type        = "https"
  description = "Primary region health check"
  method      = "GET"
  path        = var.health_check_path  # Example: /health
  interval    = 30                     # Check every 30 seconds
  timeout     = 10                     # Wait 10 seconds for response
  retries     = 2                      # Retry 2 times before marking unhealthy
  
  expected_codes = "200"               # Expect HTTP 200 OK
  expected_body  = "healthy"           # Expect this text in response
  
  header {
    header = "Host"
    values = [var.domain_name]
  }
  
  allow_insecure   = false             # Require valid SSL certificate
  follow_redirects = false
}

# Secondary Region Health Monitor
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

# ============================================
# SECTION 7: CLOUDFLARE LOAD BALANCER - POOLS
# ============================================
# Pools group origins (AWS regions) together

# Primary Pool - US-East-1
resource "cloudflare_load_balancer_pool" "primary" {
  name        = "primary-pool-${var.environment}"
  description = "Primary region pool (us-east-1)"
  
  monitor = cloudflare_load_balancer_monitor.primary.id
  
  origins {
    name    = "primary-alb"
    address = module.primary_alb.dns_name  # AWS ALB DNS name
    enabled = true
    weight  = 1
  }
  
  enabled               = true
  minimum_origins       = 1                # Need at least 1 healthy origin
  notification_email    = var.notification_email
  check_regions         = ["WNAM", "ENAM"] # Check from Western and Eastern North America
}

# Secondary Pool - US-West-2
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

# ============================================
# SECTION 8: CLOUDFLARE LOAD BALANCER - MAIN CONFIGURATION
# ============================================
# This is the CORE of our failover strategy!
# Automatically routes traffic to healthy regions

resource "cloudflare_load_balancer" "main" {
  zone_id = data.cloudflare_zone.main.id
  name    = var.domain_name
  
  # Primary pool is used by default
  default_pool_ids = [
    cloudflare_load_balancer_pool.primary.id
  ]
  
  # If primary fails, automatically use secondary
  fallback_pool_id = cloudflare_load_balancer_pool.secondary.id
  
  description = "Multi-region load balancer with automatic failover"
  proxied     = true  # Traffic goes through Cloudflare
  enabled     = true
  
  # Geo-steering: Route users to nearest region for best performance
  region_pools {
    region   = "WNAM"  # Western North America
    pool_ids = [cloudflare_load_balancer_pool.primary.id]
  }
  
  region_pools {
    region   = "ENAM"  # Eastern North America
    pool_ids = [cloudflare_load_balancer_pool.primary.id]
  }
  
  # Steering policy: Route to fastest healthy pool
  steering_policy = "dynamic_latency"
  
  # Session affinity: Keep users on same server for better experience
  session_affinity = "cookie"
  session_affinity_ttl = 3600  # 1 hour
}

# ============================================
# SECTION 9: CLOUDFLARE SSL/TLS & SECURITY SETTINGS
# ============================================
# Configure SSL, security, and performance optimizations

resource "cloudflare_zone_settings_override" "main" {
  zone_id = data.cloudflare_zone.main.id
  
  settings {
    # SSL/TLS Configuration
    ssl                      = "full"      # Full encryption between Cloudflare and origin
    always_use_https         = "on"        # Redirect HTTP to HTTPS
    min_tls_version          = "1.2"       # Minimum TLS 1.2 for security
    tls_1_3                  = "on"        # Enable TLS 1.3 for better performance
    automatic_https_rewrites = "on"        # Rewrite HTTP links to HTTPS
    
    # Security Settings
    security_level           = "medium"    # Challenge suspicious visitors
    challenge_ttl            = 1800        # Challenge valid for 30 minutes
    browser_check            = "on"        # Check for valid browser
    hotlink_protection       = "on"        # Prevent image hotlinking
    
    # Performance Optimizations
    brotli                   = "on"        # Brotli compression
    early_hints              = "on"        # Send early hints for faster loading
    http2                    = "on"        # HTTP/2 support
    http3                    = "on"        # HTTP/3 (QUIC) support
    zero_rtt                 = "on"        # 0-RTT for faster TLS handshakes
    
    # Caching
    cache_level              = "aggressive" # Cache as much as possible
    
    # Browser cache TTL
    browser_cache_ttl        = 14400       # 4 hours
  }
}

# ============================================
# SECTION 10: CLOUDFLARE WAF (WEB APPLICATION FIREWALL)
# ============================================
# Custom security rules to protect against attacks

resource "cloudflare_ruleset" "waf" {
  zone_id     = data.cloudflare_zone.main.id
  name        = "WAF Rules for ${var.domain_name}"
  description = "Custom WAF rules for application protection"
  kind        = "zone"
  phase       = "http_request_firewall_custom"
  
  # Rule 1: Block SQL Injection Attempts
  rules {
    action      = "block"
    description = "Block SQL Injection attempts"
    enabled     = true
    
    expression = "(http.request.uri.query contains \"union\" and http.request.uri.query contains \"select\") or (http.request.uri.query contains \"' or '1'='1\")"
  }
  
  # Rule 2: Rate Limiting for API Endpoints
  rules {
    action      = "challenge"
    description = "Rate limit API endpoints"
    enabled     = true
    
    expression = "(http.request.uri.path contains \"/api/\") and (rate(5m) > 100)"
  }
  
  # Rule 3: Block Known Malicious Tools
  rules {
    action      = "block"
    description = "Block malicious user agents"
    enabled     = true
    
    expression = "(http.user_agent contains \"sqlmap\") or (http.user_agent contains \"nikto\") or (http.user_agent contains \"nmap\")"
  }
}

# ============================================
# SECTION 11: CLOUDFLARE PAGE RULES
# ============================================
# Optimize caching for different types of content

# Cache static files aggressively (images, CSS, JS)
resource "cloudflare_page_rule" "cache_static" {
  zone_id  = data.cloudflare_zone.main.id
  target   = "${var.domain_name}/static/*"
  priority = 1
  
  actions {
    cache_level         = "cache_everything"
    edge_cache_ttl      = 86400  # 24 hours at Cloudflare edge
    browser_cache_ttl   = 86400  # 24 hours in browser
  }
}

# Bypass cache for API endpoints (always get fresh data)
resource "cloudflare_page_rule" "cache_api" {
  zone_id  = data.cloudflare_zone.main.id
  target   = "${var.domain_name}/api/*"
  priority = 2
  
  actions {
    cache_level = "bypass"  # Don't cache API responses
  }
}

# ============================================
# SECTION 12: CLOUDFLARE RATE LIMITING
# ============================================
# Protect login endpoints from brute force attacks

resource "cloudflare_rate_limit" "login" {
  zone_id   = data.cloudflare_zone.main.id
  threshold = 5      # Maximum 5 requests
  period    = 60     # Per 60 seconds (1 minute)
  
  match {
    request {
      url_pattern = "${var.domain_name}/login"
    }
  }
  
  action {
    mode    = "challenge"  # Show CAPTCHA challenge
    timeout = 3600         # Block for 1 hour if failed
  }
  
  description = "Rate limit login attempts to prevent brute force"
}

# ============================================
# SECTION 13: AWS CLOUDWATCH MONITORING & ALERTS
# ============================================
# Monitor health and send alerts when issues occur

# Alert when primary ALB has no healthy targets
resource "aws_cloudwatch_metric_alarm" "primary_alb_unhealthy" {
  alarm_name          = "primary-alb-unhealthy-targets"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"              # Check for 2 consecutive periods
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = "60"             # Check every 60 seconds
  statistic           = "Average"
  threshold           = "1"              # Alert if less than 1 healthy host
  alarm_description   = "Alert when primary ALB has no healthy targets"
  
  dimensions = {
    LoadBalancer = module.primary_alb.arn_suffix
  }
  
  alarm_actions = [aws_sns_topic.alerts.arn]
}

# SNS Topic for sending email/SMS alerts
resource "aws_sns_topic" "alerts" {
  name = "cloudflare-aws-integration-alerts"
}

# Subscribe email to receive alerts
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# ============================================
# SECTION 14: OUTPUTS
# ============================================
# These values are displayed after terraform apply

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
