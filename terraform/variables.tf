# ============================================
# GENERAL SETTINGS
# ============================================

variable "environment" {
  description = "Environment name (e.g., production, staging)"
  type        = string
  default     = "production"
}

variable "owner_email" {
  description = "Email of the infrastructure owner"
  type        = string
}

variable "notification_email" {
  description = "Email for alerts and notifications"
  type        = string
}

# ============================================
# DOMAIN & DNS
# ============================================

variable "domain_name" {
  description = "Primary domain name (e.g., example.com)"
  type        = string
}

# ============================================
# CLOUDFLARE
# ============================================

variable "cloudflare_api_token" {
  description = "Cloudflare API token with appropriate permissions"
  type        = string
  sensitive   = true
}

# ============================================
# AWS REGIONS
# ============================================

variable "primary_region" {
  description = "Primary AWS region"
  type        = string
  default     = "us-east-1"
}

variable "secondary_region" {
  description = "Secondary AWS region for failover"
  type        = string
  default     = "us-west-2"
}

# ============================================
# NETWORKING - PRIMARY REGION
# ============================================

variable "primary_vpc_cidr" {
  description = "CIDR block for primary VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "primary_azs" {
  description = "Availability zones for primary region"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

# ============================================
# NETWORKING - SECONDARY REGION
# ============================================

variable "secondary_vpc_cidr" {
  description = "CIDR block for secondary VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "secondary_azs" {
  description = "Availability zones for secondary region"
  type        = list(string)
  default     = ["us-west-2a", "us-west-2b", "us-west-2c"]
}

# ============================================
# COMPUTE
# ============================================

variable "instance_type" {
  description = "EC2 instance type for compute resources"
  type        = string
  default     = "t3.medium"
}

variable "min_instances" {
  description = "Minimum number of instances in primary region"
  type        = number
  default     = 2
}

variable "max_instances" {
  description = "Maximum number of instances in primary region"
  type        = number
  default     = 10
}

variable "desired_instances" {
  description = "Desired number of instances in primary region"
  type        = number
  default     = 3
}

variable "min_instances_secondary" {
  description = "Minimum number of instances in secondary region"
  type        = number
  default     = 1
}

variable "max_instances_secondary" {
  description = "Maximum number of instances in secondary region"
  type        = number
  default     = 5
}

variable "desired_instances_secondary" {
  description = "Desired number of instances in secondary region"
  type        = number
  default     = 2
}

# ============================================
# DATABASE
# ============================================

variable "database_name" {
  description = "Name of the RDS database"
  type        = string
  default     = "appdb"
}

variable "db_master_username" {
  description = "Master username for RDS"
  type        = string
  default     = "admin"
  sensitive   = true
}

variable "db_master_password" {
  description = "Master password for RDS"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "db_allocated_storage" {
  description = "Allocated storage for RDS (GB)"
  type        = number
  default     = 100
}

# ============================================
# HEALTH CHECKS
# ============================================

variable "health_check_path" {
  description = "Path for health check endpoint"
  type        = string
  default     = "/health"
}

variable "health_check_interval" {
  description = "Health check interval in seconds"
  type        = number
  default     = 30
}

variable "health_check_timeout" {
  description = "Health check timeout in seconds"
  type        = number
  default     = 10
}

variable "health_check_healthy_threshold" {
  description = "Number of consecutive successful health checks"
  type        = number
  default     = 2
}

variable "health_check_unhealthy_threshold" {
  description = "Number of consecutive failed health checks"
  type        = number
  default     = 3
}

# ============================================
# SSL/TLS
# ============================================

variable "ssl_policy" {
  description = "SSL policy for ALB"
  type        = string
  default     = "ELBSecurityPolicy-TLS-1-2-2017-01"
}

# ============================================
# TAGS
# ============================================

variable "additional_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
