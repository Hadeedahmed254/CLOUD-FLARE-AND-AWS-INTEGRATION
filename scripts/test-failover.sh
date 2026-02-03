#!/bin/bash

# Failover Testing Script
# Simulates region failures and monitors automatic failover

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
DOMAIN="${DOMAIN:-example.com}"
PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
SECONDARY_REGION="${SECONDARY_REGION:-us-west-2}"

# Parse command line arguments
ACTION=""
REGION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --region)
            REGION="$2"
            shift 2
            ;;
        --action)
            ACTION="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 --region <region> --action <enable|disable>"
            exit 1
            ;;
    esac
done

# Validate inputs
if [ -z "$REGION" ] || [ -z "$ACTION" ]; then
    echo "Usage: $0 --region <region> --action <enable|disable>"
    echo ""
    echo "Examples:"
    echo "  # Disable primary region (simulate failure)"
    echo "  $0 --region us-east-1 --action disable"
    echo ""
    echo "  # Re-enable primary region"
    echo "  $0 --region us-east-1 --action enable"
    exit 1
fi

echo -e "${BLUE}================================================${NC}"
echo -e "${BLUE}Failover Testing Script${NC}"
echo -e "${BLUE}================================================${NC}"
echo ""
echo "Domain: $DOMAIN"
echo "Region: $REGION"
echo "Action: $ACTION"
echo ""

# Function to get current serving region
get_serving_region() {
    RESPONSE=$(curl -s -I https://$DOMAIN)
    if echo "$RESPONSE" | grep -q "X-Served-By.*us-east"; then
        echo "us-east-1"
    elif echo "$RESPONSE" | grep -q "X-Served-By.*us-west"; then
        echo "us-west-2"
    else
        echo "unknown"
    fi
}

# Function to check health endpoint
check_health() {
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" https://$DOMAIN/health)
    echo "$STATUS"
}

# Function to disable region
disable_region() {
    local region=$1
    echo -e "${YELLOW}Disabling region: $region${NC}"
    echo ""
    
    # Get Auto Scaling Group name
    ASG_NAME=$(aws autoscaling describe-auto-scaling-groups \
        --region $region \
        --query 'AutoScalingGroups[?contains(AutoScalingGroupName, `primary`) || contains(AutoScalingGroupName, `secondary`)].AutoScalingGroupName' \
        --output text)
    
    if [ -z "$ASG_NAME" ]; then
        echo -e "${RED}Error: Could not find Auto Scaling Group in $region${NC}"
        exit 1
    fi
    
    echo "Found Auto Scaling Group: $ASG_NAME"
    
    # Store current capacity
    CURRENT_CAPACITY=$(aws autoscaling describe-auto-scaling-groups \
        --region $region \
        --auto-scaling-group-names $ASG_NAME \
        --query 'AutoScalingGroups[0].DesiredCapacity' \
        --output text)
    
    echo "Current capacity: $CURRENT_CAPACITY"
    echo "Setting capacity to 0..."
    
    # Set capacity to 0
    aws autoscaling set-desired-capacity \
        --region $region \
        --auto-scaling-group-name $ASG_NAME \
        --desired-capacity 0
    
    aws autoscaling update-auto-scaling-group \
        --region $region \
        --auto-scaling-group-name $ASG_NAME \
        --min-size 0 \
        --max-size 0
    
    echo -e "${GREEN}✓ Region disabled${NC}"
    echo ""
    echo "Waiting for instances to terminate..."
    sleep 30
}

# Function to enable region
enable_region() {
    local region=$1
    echo -e "${GREEN}Enabling region: $region${NC}"
    echo ""
    
    # Get Auto Scaling Group name
    ASG_NAME=$(aws autoscaling describe-auto-scaling-groups \
        --region $region \
        --query 'AutoScalingGroups[?contains(AutoScalingGroupName, `primary`) || contains(AutoScalingGroupName, `secondary`)].AutoScalingGroupName' \
        --output text)
    
    if [ -z "$ASG_NAME" ]; then
        echo -e "${RED}Error: Could not find Auto Scaling Group in $region${NC}"
        exit 1
    fi
    
    echo "Found Auto Scaling Group: $ASG_NAME"
    
    # Restore capacity
    if [ "$region" = "$PRIMARY_REGION" ]; then
        DESIRED=3
        MIN=2
        MAX=10
    else
        DESIRED=2
        MIN=1
        MAX=5
    fi
    
    echo "Restoring capacity to: $DESIRED (min: $MIN, max: $MAX)"
    
    aws autoscaling update-auto-scaling-group \
        --region $region \
        --auto-scaling-group-name $ASG_NAME \
        --min-size $MIN \
        --max-size $MAX \
        --desired-capacity $DESIRED
    
    echo -e "${GREEN}✓ Region enabled${NC}"
    echo ""
    echo "Waiting for instances to launch..."
    sleep 60
}

# Function to monitor failover
monitor_failover() {
    echo -e "${BLUE}Monitoring failover process...${NC}"
    echo ""
    
    START_TIME=$(date +%s)
    FAILOVER_DETECTED=false
    INITIAL_REGION=$(get_serving_region)
    
    echo "Initial serving region: $INITIAL_REGION"
    echo ""
    
    for i in {1..60}; do
        CURRENT_REGION=$(get_serving_region)
        HEALTH_STATUS=$(check_health)
        CURRENT_TIME=$(date +%s)
        ELAPSED=$((CURRENT_TIME - START_TIME))
        
        echo -n "[$ELAPSED s] Region: $CURRENT_REGION | Health: $HEALTH_STATUS"
        
        if [ "$CURRENT_REGION" != "$INITIAL_REGION" ] && [ "$FAILOVER_DETECTED" = false ]; then
            FAILOVER_DETECTED=true
            FAILOVER_TIME=$ELAPSED
            echo -e " ${GREEN}✓ FAILOVER DETECTED!${NC}"
            echo ""
            echo -e "${GREEN}Failover completed in $FAILOVER_TIME seconds${NC}"
            echo ""
        else
            echo ""
        fi
        
        sleep 5
    done
    
    if [ "$FAILOVER_DETECTED" = false ]; then
        echo -e "${YELLOW}Warning: No failover detected after 5 minutes${NC}"
    fi
}

# Main execution
echo -e "${BLUE}Step 1: Recording baseline${NC}"
INITIAL_REGION=$(get_serving_region)
INITIAL_HEALTH=$(check_health)
echo "Current serving region: $INITIAL_REGION"
echo "Current health status: $INITIAL_HEALTH"
echo ""

if [ "$ACTION" = "disable" ]; then
    echo -e "${BLUE}Step 2: Disabling region${NC}"
    disable_region $REGION
    
    echo -e "${BLUE}Step 3: Monitoring failover${NC}"
    monitor_failover
    
    echo ""
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}Failover Test Complete${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo ""
    echo "Summary:"
    echo "  - Initial region: $INITIAL_REGION"
    echo "  - Disabled region: $REGION"
    echo "  - Current region: $(get_serving_region)"
    echo "  - Current health: $(check_health)"
    echo ""
    echo "To restore the region, run:"
    echo "  $0 --region $REGION --action enable"
    echo ""
    
elif [ "$ACTION" = "enable" ]; then
    echo -e "${BLUE}Step 2: Enabling region${NC}"
    enable_region $REGION
    
    echo -e "${BLUE}Step 3: Verifying health${NC}"
    sleep 30
    
    FINAL_HEALTH=$(check_health)
    FINAL_REGION=$(get_serving_region)
    
    echo ""
    echo -e "${GREEN}================================================${NC}"
    echo -e "${GREEN}Region Restoration Complete${NC}"
    echo -e "${GREEN}================================================${NC}"
    echo ""
    echo "Summary:"
    echo "  - Restored region: $REGION"
    echo "  - Current serving region: $FINAL_REGION"
    echo "  - Current health status: $FINAL_HEALTH"
    echo ""
    
    if [ "$FINAL_HEALTH" = "200" ]; then
        echo -e "${GREEN}✓ System is healthy${NC}"
    else
        echo -e "${RED}✗ System health check failed${NC}"
    fi
    echo ""
else
    echo -e "${RED}Invalid action: $ACTION${NC}"
    echo "Valid actions: enable, disable"
    exit 1
fi
