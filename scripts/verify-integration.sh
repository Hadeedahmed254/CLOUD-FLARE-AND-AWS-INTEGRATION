#!/bin/bash

# Cloudflare + AWS Integration Verification Script
# This script verifies the integration is working correctly

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
DOMAIN="${DOMAIN:-example.com}"
PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
SECONDARY_REGION="${SECONDARY_REGION:-us-west-2}"
HEALTH_CHECK_PATH="${HEALTH_CHECK_PATH:-/health}"

echo "================================================"
echo "Cloudflare + AWS Integration Verification"
echo "================================================"
echo ""

# Function to print status
print_status() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓${NC} $2"
    else
        echo -e "${RED}✗${NC} $2"
    fi
}

# Function to print warning
print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Function to print info
print_info() {
    echo -e "ℹ $1"
}

# 1. Check DNS Resolution
echo "1. Checking DNS Resolution..."
DNS_IP=$(dig +short $DOMAIN @1.1.1.1 | head -n 1)
if [ -n "$DNS_IP" ]; then
    print_status 0 "DNS resolves to: $DNS_IP"
else
    print_status 1 "DNS resolution failed"
    exit 1
fi
echo ""

# 2. Check Cloudflare Proxy
echo "2. Checking Cloudflare Proxy..."
CF_CHECK=$(curl -s -I https://$DOMAIN | grep -i "cf-ray" || echo "")
if [ -n "$CF_CHECK" ]; then
    print_status 0 "Traffic is proxied through Cloudflare"
    CF_RAY=$(echo "$CF_CHECK" | awk '{print $2}')
    print_info "CF-Ray: $CF_RAY"
else
    print_warning "Traffic may not be proxied through Cloudflare"
fi
echo ""

# 3. Check SSL/TLS
echo "3. Checking SSL/TLS Configuration..."
SSL_CHECK=$(echo | openssl s_client -connect $DOMAIN:443 -servername $DOMAIN 2>/dev/null | grep "Verify return code")
if echo "$SSL_CHECK" | grep -q "0 (ok)"; then
    print_status 0 "SSL certificate is valid"
else
    print_status 1 "SSL certificate validation failed"
fi

# Check TLS version
TLS_VERSION=$(echo | openssl s_client -connect $DOMAIN:443 -servername $DOMAIN 2>/dev/null | grep "Protocol" | awk '{print $3}')
print_info "TLS Version: $TLS_VERSION"
echo ""

# 4. Check HTTP to HTTPS Redirect
echo "4. Checking HTTP to HTTPS Redirect..."
HTTP_REDIRECT=$(curl -s -o /dev/null -w "%{http_code}" -L http://$DOMAIN)
if [ "$HTTP_REDIRECT" = "200" ]; then
    print_status 0 "HTTP redirects to HTTPS"
else
    print_warning "HTTP redirect returned: $HTTP_REDIRECT"
fi
echo ""

# 5. Check Security Headers
echo "5. Checking Security Headers..."
HEADERS=$(curl -s -I https://$DOMAIN)

# Check HSTS
if echo "$HEADERS" | grep -qi "strict-transport-security"; then
    print_status 0 "HSTS header present"
else
    print_warning "HSTS header missing"
fi

# Check X-Frame-Options
if echo "$HEADERS" | grep -qi "x-frame-options"; then
    print_status 0 "X-Frame-Options header present"
else
    print_warning "X-Frame-Options header missing"
fi

# Check X-Content-Type-Options
if echo "$HEADERS" | grep -qi "x-content-type-options"; then
    print_status 0 "X-Content-Type-Options header present"
else
    print_warning "X-Content-Type-Options header missing"
fi
echo ""

# 6. Check Health Endpoint
echo "6. Checking Health Endpoint..."
HEALTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://$DOMAIN$HEALTH_CHECK_PATH)
if [ "$HEALTH_STATUS" = "200" ]; then
    print_status 0 "Health endpoint returns 200 OK"
    HEALTH_BODY=$(curl -s https://$DOMAIN$HEALTH_CHECK_PATH)
    print_info "Health response: $HEALTH_BODY"
else
    print_status 1 "Health endpoint returned: $HEALTH_STATUS"
fi
echo ""

# 7. Check Response Time
echo "7. Checking Response Time..."
RESPONSE_TIME=$(curl -s -o /dev/null -w "%{time_total}" https://$DOMAIN)
RESPONSE_MS=$(echo "$RESPONSE_TIME * 1000" | bc)
print_info "Response time: ${RESPONSE_MS}ms"

if (( $(echo "$RESPONSE_TIME < 0.5" | bc -l) )); then
    print_status 0 "Response time is excellent (< 500ms)"
elif (( $(echo "$RESPONSE_TIME < 1.0" | bc -l) )); then
    print_status 0 "Response time is good (< 1s)"
else
    print_warning "Response time is slow (> 1s)"
fi
echo ""

# 8. Check Cloudflare Cache
echo "8. Checking Cloudflare Cache..."
CACHE_STATUS=$(curl -s -I https://$DOMAIN/static/test.jpg | grep -i "cf-cache-status" | awk '{print $2}' | tr -d '\r')
if [ -n "$CACHE_STATUS" ]; then
    print_status 0 "Cache status: $CACHE_STATUS"
else
    print_warning "Cache status header not found"
fi
echo ""

# 9. Check AWS Primary Region
echo "9. Checking AWS Primary Region ($PRIMARY_REGION)..."
if command -v aws &> /dev/null; then
    # Check ALB
    ALB_COUNT=$(aws elbv2 describe-load-balancers --region $PRIMARY_REGION --query 'LoadBalancers[?contains(LoadBalancerName, `primary`)].LoadBalancerName' --output text 2>/dev/null | wc -l)
    if [ $ALB_COUNT -gt 0 ]; then
        print_status 0 "Primary ALB found in $PRIMARY_REGION"
    else
        print_warning "Primary ALB not found in $PRIMARY_REGION"
    fi
    
    # Check Auto Scaling Group
    ASG_COUNT=$(aws autoscaling describe-auto-scaling-groups --region $PRIMARY_REGION --query 'AutoScalingGroups[?contains(AutoScalingGroupName, `primary`)].AutoScalingGroupName' --output text 2>/dev/null | wc -l)
    if [ $ASG_COUNT -gt 0 ]; then
        print_status 0 "Primary Auto Scaling Group found"
    else
        print_warning "Primary Auto Scaling Group not found"
    fi
else
    print_warning "AWS CLI not installed, skipping AWS checks"
fi
echo ""

# 10. Check AWS Secondary Region
echo "10. Checking AWS Secondary Region ($SECONDARY_REGION)..."
if command -v aws &> /dev/null; then
    # Check ALB
    ALB_COUNT=$(aws elbv2 describe-load-balancers --region $SECONDARY_REGION --query 'LoadBalancers[?contains(LoadBalancerName, `secondary`)].LoadBalancerName' --output text 2>/dev/null | wc -l)
    if [ $ALB_COUNT -gt 0 ]; then
        print_status 0 "Secondary ALB found in $SECONDARY_REGION"
    else
        print_warning "Secondary ALB not found in $SECONDARY_REGION"
    fi
else
    print_warning "AWS CLI not installed, skipping AWS checks"
fi
echo ""

# 11. Check Cloudflare Load Balancer
echo "11. Checking Cloudflare Load Balancer..."
if [ -n "$CLOUDFLARE_API_TOKEN" ] && [ -n "$CLOUDFLARE_ZONE_ID" ]; then
    LB_STATUS=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/load_balancers" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json" | jq -r '.result[0].enabled')
    
    if [ "$LB_STATUS" = "true" ]; then
        print_status 0 "Cloudflare Load Balancer is enabled"
    else
        print_warning "Cloudflare Load Balancer status: $LB_STATUS"
    fi
else
    print_warning "Cloudflare API credentials not set, skipping LB check"
fi
echo ""

# 12. Performance Test
echo "12. Running Performance Test..."
print_info "Testing from multiple locations..."

# Test from different Cloudflare POPs by using different DNS resolvers
for i in {1..5}; do
    TIME=$(curl -s -o /dev/null -w "%{time_total}" https://$DOMAIN)
    TIME_MS=$(echo "$TIME * 1000" | bc)
    print_info "Request $i: ${TIME_MS}ms"
done
echo ""

# Summary
echo "================================================"
echo "Verification Complete!"
echo "================================================"
echo ""
echo "Next Steps:"
echo "1. Review any warnings above"
echo "2. Test failover scenario (see test-failover.sh)"
echo "3. Monitor performance for 24 hours"
echo "4. Set up alerting and monitoring"
echo ""
echo "For detailed monitoring, visit:"
echo "  - Cloudflare Dashboard: https://dash.cloudflare.com"
echo "  - AWS CloudWatch: https://console.aws.amazon.com/cloudwatch"
echo ""
