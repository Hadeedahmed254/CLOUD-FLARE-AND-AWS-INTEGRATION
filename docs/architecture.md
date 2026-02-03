# Architecture Deep Dive

## Table of Contents
1. [Overview](#overview)
2. [Network Architecture](#network-architecture)
3. [Failover Strategy](#failover-strategy)
4. [Security Architecture](#security-architecture)
5. [Data Flow](#data-flow)
6. [Disaster Recovery](#disaster-recovery)

## Overview

This architecture implements a **highly available, multi-region deployment** with Cloudflare as the global edge layer and AWS as the compute/storage infrastructure.

### Key Design Principles

1. **High Availability**: Multi-AZ deployment in each region
2. **Disaster Recovery**: Cross-region failover with < 60 second RTO
3. **Security First**: Multiple layers of protection (WAF, DDoS, SSL/TLS)
4. **Performance**: Global CDN with intelligent routing
5. **Cost Optimization**: Auto-scaling and efficient caching

## Network Architecture

### Primary Region (us-east-1)

```
┌─────────────────────────────────────────────────────────────┐
│                    VPC (10.0.0.0/16)                        │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │           PUBLIC SUBNETS (3 AZs)                     │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐     │  │
│  │  │ 10.0.1.0/24│  │ 10.0.2.0/24│  │ 10.0.3.0/24│     │  │
│  │  │   AZ-1a    │  │   AZ-1b    │  │   AZ-1c    │     │  │
│  │  └─────┬──────┘  └─────┬──────┘  └─────┬──────┘     │  │
│  └────────┼───────────────┼───────────────┼────────────┘  │
│           │               │               │                │
│      ┌────▼───────────────▼───────────────▼────┐          │
│      │   Application Load Balancer (ALB)       │          │
│      │   - SSL Termination                     │          │
│      │   - Health Checks                       │          │
│      │   - Target Groups                       │          │
│      └────┬───────────────┬───────────────┬────┘          │
│           │               │               │                │
│  ┌────────▼───────────────▼───────────────▼────────────┐  │
│  │           PRIVATE SUBNETS (3 AZs)                   │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐    │  │
│  │  │10.0.11.0/24│  │10.0.12.0/24│  │10.0.13.0/24│    │  │
│  │  │            │  │            │  │            │    │  │
│  │  │  EC2/ECS   │  │  EC2/ECS   │  │  EC2/ECS   │    │  │
│  │  │ Instances  │  │ Instances  │  │ Instances  │    │  │
│  │  │            │  │            │  │            │    │  │
│  │  └─────┬──────┘  └─────┬──────┘  └─────┬──────┘    │  │
│  └────────┼───────────────┼───────────────┼───────────┘  │
│           │               │               │               │
│  ┌────────▼───────────────▼───────────────▼───────────┐  │
│  │           DATABASE SUBNETS (3 AZs)                 │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐   │  │
│  │  │10.0.21.0/24│  │10.0.22.0/24│  │10.0.23.0/24│   │  │
│  │  │            │  │            │  │            │   │  │
│  │  │ RDS Primary│  │RDS Standby │  │ElastiCache │   │  │
│  │  │  (Multi-AZ)│  │            │  │            │   │  │
│  │  └────────────┘  └────────────┘  └────────────┘   │  │
│  └────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Secondary Region (us-west-2)

Similar architecture with:
- VPC CIDR: 10.1.0.0/16
- RDS Read Replica (can be promoted to primary)
- Reduced capacity (cost optimization)
- Same security posture

## Failover Strategy

### Three-Layer Failover Approach

#### Layer 1: Cloudflare Load Balancer (Primary)

**How it works:**
1. Cloudflare monitors both regions every 30 seconds
2. Health checks hit `/health` endpoint on each ALB
3. If primary fails 2 consecutive checks (60 seconds), traffic shifts to secondary
4. Automatic recovery when primary is healthy again

**Configuration:**
```hcl
monitor {
  interval = 30 seconds
  timeout  = 10 seconds
  retries  = 2
  path     = "/health"
}

steering_policy = "dynamic_latency"  # Routes to fastest healthy pool
```

**RTO (Recovery Time Objective):** < 60 seconds  
**RPO (Recovery Point Objective):** Near-zero (database replication lag < 5 seconds)

#### Layer 2: Route53 Health Checks (Backup)

If Cloudflare itself has issues:
1. Route53 health checks monitor both regions
2. Failover DNS records point to secondary region
3. DNS TTL: 60 seconds for faster propagation

**RTO:** 60-90 seconds (DNS propagation)

#### Layer 3: Static Fallback Page

If both regions fail:
1. Cloudflare Worker serves static maintenance page from S3
2. Maintains brand presence
3. Provides status updates and contact information

### Failover Testing Procedure

```bash
# 1. Simulate primary region failure
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name primary-asg \
  --desired-capacity 0 \
  --region us-east-1

# 2. Monitor Cloudflare Load Balancer
watch -n 5 'curl -s https://api.cloudflare.com/client/v4/zones/{zone_id}/load_balancers/{lb_id}/pools | jq'

# 3. Verify traffic shifted to secondary
curl -I https://yourdomain.com
# Should show X-Served-By: us-west-2

# 4. Restore primary region
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name primary-asg \
  --desired-capacity 3 \
  --region us-east-1

# 5. Verify automatic recovery
# Traffic should shift back to primary within 2-3 minutes
```

## Security Architecture

### Defense in Depth Strategy

```
┌─────────────────────────────────────────────────────────┐
│ Layer 1: Cloudflare Edge (Global)                      │
│ - DDoS Protection (Layers 3, 4, 7)                     │
│ - WAF (OWASP Top 10)                                   │
│ - Bot Management                                       │
│ - Rate Limiting                                        │
│ - SSL/TLS Encryption                                   │
└────────────────────┬────────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────────┐
│ Layer 2: AWS Network Security                          │
│ - Security Groups (Stateful Firewall)                  │
│ - Network ACLs (Stateless Firewall)                    │
│ - VPC Isolation                                        │
│ - Private Subnets for Compute/Database                 │
└────────────────────┬────────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────────┐
│ Layer 3: Application Security                          │
│ - ALB with SSL Termination                             │
│ - AWS WAF (Additional Rules)                           │
│ - Secrets Manager for Credentials                      │
│ - IAM Roles (Least Privilege)                          │
└────────────────────┬────────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────────┐
│ Layer 4: Data Security                                 │
│ - RDS Encryption at Rest (KMS)                         │
│ - Encryption in Transit (SSL/TLS)                      │
│ - Automated Backups (7-day retention)                  │
│ - Database Subnet Isolation                            │
└─────────────────────────────────────────────────────────┘
```

### WAF Rules Implemented

1. **SQL Injection Protection**
   - Blocks common SQL injection patterns
   - Monitors query parameters and POST bodies

2. **XSS Protection**
   - Sanitizes user input
   - Blocks script injection attempts

3. **Rate Limiting**
   - Login: 5 attempts/minute per IP
   - API: 100 requests/minute per IP
   - Search: 20 requests/minute per IP

4. **Geo-Blocking** (Optional)
   - Block/challenge traffic from specific countries
   - Useful for compliance requirements

5. **Bot Protection**
   - Block known malicious bots
   - Challenge suspicious user agents
   - Allow verified bots (Google, Bing)

## Data Flow

### Normal Operation (Primary Region Active)

```
User Request
    │
    ▼
Cloudflare Edge (Nearest POP)
    │
    ├─ Cache Hit? → Return Cached Response
    │
    └─ Cache Miss
        │
        ▼
    Cloudflare Load Balancer
        │
        ▼
    Primary Region ALB (us-east-1)
        │
        ▼
    EC2/ECS Instances
        │
        ├─ Read from ElastiCache (if cached)
        │
        └─ Query RDS (if not cached)
            │
            ▼
        Response
            │
            ▼
    Cloudflare Edge (Cache for future requests)
            │
            ▼
        User
```

### Failover Scenario (Primary Region Down)

```
User Request
    │
    ▼
Cloudflare Edge
    │
    ▼
Cloudflare Load Balancer
    │
    ├─ Health Check Primary: FAIL
    │
    └─ Automatic Failover
        │
        ▼
    Secondary Region ALB (us-west-2)
        │
        ▼
    EC2/ECS Instances (Secondary)
        │
        ▼
    RDS Read Replica (Promoted to Primary if needed)
        │
        ▼
    Response to User
```

## Disaster Recovery

### Backup Strategy

1. **Database Backups**
   - Automated daily snapshots
   - 7-day retention period
   - Cross-region backup replication
   - Point-in-time recovery (5-minute granularity)

2. **Application Backups**
   - AMI snapshots of EC2 instances
   - ECS task definitions versioned in S3
   - Infrastructure as Code in Git

3. **Configuration Backups**
   - Terraform state in S3 with versioning
   - Cloudflare configuration exported daily

### Recovery Procedures

#### Scenario 1: Single AZ Failure
- **Impact**: Minimal (Multi-AZ deployment)
- **Action**: Automatic (AWS handles)
- **RTO**: < 5 minutes

#### Scenario 2: Primary Region Failure
- **Impact**: Moderate (Failover to secondary)
- **Action**: Automatic (Cloudflare LB)
- **RTO**: < 60 seconds

#### Scenario 3: Complete Outage (Both Regions)
- **Impact**: High
- **Action**: Manual recovery from backups
- **RTO**: 2-4 hours
- **Procedure**:
  1. Identify root cause
  2. Deploy to new region using Terraform
  3. Restore database from latest snapshot
  4. Update Cloudflare load balancer pools
  5. Verify functionality
  6. Resume traffic

#### Scenario 4: Data Corruption
- **Impact**: Variable
- **Action**: Point-in-time recovery
- **RTO**: 30-60 minutes
- **Procedure**:
  1. Identify corruption timestamp
  2. Create new RDS instance from snapshot
  3. Restore to point before corruption
  4. Update application configuration
  5. Verify data integrity

### Testing Schedule

- **Monthly**: Failover testing (primary to secondary)
- **Quarterly**: Full DR drill (restore from backup)
- **Annually**: Complete disaster simulation

## Performance Optimization

### Caching Strategy

1. **Cloudflare Edge Cache**
   - Static assets: 24 hours
   - API responses: Bypass cache
   - HTML pages: 2 hours (with cache tags for purging)

2. **ElastiCache (Redis)**
   - Session data: 1 hour TTL
   - Database query results: 5-15 minutes TTL
   - API responses: 1-5 minutes TTL

3. **Browser Cache**
   - Static assets: 24 hours
   - HTML: No cache (always revalidate)

### Expected Performance Metrics

- **Global Latency**: < 50ms (Cloudflare edge)
- **Origin Latency**: < 200ms (AWS)
- **Cache Hit Ratio**: > 80%
- **Availability**: 99.99% (52 minutes downtime/year)

## Cost Analysis

### Monthly Cost Breakdown

**Cloudflare:**
- Pro Plan: $20/month
- Load Balancer: $10/month (2 origins)
- **Total**: ~$30/month

**AWS Primary Region:**
- EC2/ECS: $200-400
- ALB: $25
- RDS: $150
- ElastiCache: $50
- Data Transfer: $100
- **Subtotal**: ~$525-725/month

**AWS Secondary Region:**
- EC2/ECS: $100-200
- ALB: $25
- RDS Replica: $150
- ElastiCache: $50
- **Subtotal**: ~$325-425/month

**Total Estimated Cost**: $880-1,180/month

### Cost Optimization Opportunities

1. **Reserved Instances**: Save 30-50% on predictable workloads
2. **Spot Instances**: Save 70-90% on fault-tolerant workloads
3. **Cloudflare Caching**: Reduce AWS data transfer by 60-80%
4. **Auto-scaling**: Scale down during low-traffic periods
5. **S3 Lifecycle Policies**: Move old backups to Glacier

## Monitoring & Observability

### Key Metrics

1. **Availability Metrics**
   - Uptime percentage
   - Health check success rate
   - Failover events

2. **Performance Metrics**
   - Response time (p50, p95, p99)
   - Cache hit ratio
   - Database query time

3. **Security Metrics**
   - WAF blocks
   - DDoS attacks mitigated
   - Failed login attempts

4. **Cost Metrics**
   - Monthly spend by service
   - Data transfer costs
   - Reserved vs on-demand usage

### Alerting Thresholds

- **Critical**: Uptime < 99.9%, Response time > 1s
- **Warning**: Uptime < 99.95%, Response time > 500ms
- **Info**: Cache hit ratio < 70%, Unusual traffic patterns

## Conclusion

This architecture provides:
- ✅ **High Availability**: 99.99% uptime SLA
- ✅ **Fast Failover**: < 60 second RTO
- ✅ **Global Performance**: < 50ms edge latency
- ✅ **Enterprise Security**: Multi-layer protection
- ✅ **Cost Effective**: Optimized for performance/cost ratio
- ✅ **Scalable**: Auto-scaling to handle traffic spikes
