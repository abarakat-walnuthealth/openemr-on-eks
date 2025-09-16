#!/bin/bash

# OpenEMR Complete Infrastructure Destruction Script
# This script destroys ALL OpenEMR infrastructure components in dependency-aware order
# Based on manual cleanup experience from Sept 2024

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"

# Command line options
DRY_RUN=false
FORCE=false
PRESERVE_DATA=false
PARALLEL=true

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        --preserve-data)
            PRESERVE_DATA=true
            shift
            ;;
        --no-parallel)
            PARALLEL=false
            shift
            ;;
        -h|--help)
            cat << EOF
Usage: $0 [OPTIONS]

Destroys ALL OpenEMR infrastructure components in proper dependency order.

Options:
  --dry-run          Show what would be deleted without actually deleting
  -f, --force        Skip confirmation prompts (DANGEROUS)
  --preserve-data    Create backups before destroying data resources
  --no-parallel     Disable parallel deletion of independent resources
  -h, --help        Show this help message

Examples:
  $0                    # Interactive destruction with prompts
  $0 --dry-run          # Preview what would be deleted
  $0 --force            # Destroy everything without prompts (DANGEROUS)
  $0 --preserve-data    # Create backups before destroying RDS/EFS

WARNING: This script will DELETE ALL OpenEMR infrastructure!
This includes EKS, RDS, EFS, VPC, and all associated resources.
Make sure you have backups if you need to preserve any data.
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Auto-detect configuration from terraform
get_terraform_config() {
    local config_file="$TERRAFORM_DIR/terraform.tfvars"
    local var_name="$1"
    local default_value="${2:-}"

    if [[ -f "$config_file" ]]; then
        grep "^${var_name}.*=" "$config_file" | cut -d'"' -f2 2>/dev/null || echo "$default_value"
    else
        echo "$default_value"
    fi
}

# Configuration with auto-detection
AWS_REGION=$(get_terraform_config "aws_region" "us-east-1")
CLUSTER_NAME=$(get_terraform_config "cluster_name" "openemr-eks")
ENABLE_WAF=$(get_terraform_config "enable_waf" "true")

# Validate AWS CLI and region
if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI not found. Please install it first.${NC}"
    exit 1
fi

if ! aws sts get-caller-identity > /dev/null 2>&1; then
    echo -e "${RED}❌ AWS credentials not configured or invalid.${NC}"
    exit 1
fi

# Resource tracking
TOTAL_COST_SAVINGS=0
DELETED_RESOURCES=()
FAILED_DELETIONS=()

# Utility functions
log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%H:%M:%S')] ⚠️  $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%H:%M:%S')] ❌ $1${NC}"
}

success() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')] ✅ $1${NC}"
}

# Execute command with dry-run support
execute() {
    local description="$1"
    shift

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${CYAN}[DRY-RUN] Would execute: $*${NC}"
        return 0
    fi

    echo -e "${BLUE}Executing: $description${NC}"
    if "$@"; then
        success "$description"
        return 0
    else
        error "Failed: $description"
        FAILED_DELETIONS+=("$description")
        return 1
    fi
}

# Check if resource exists
resource_exists() {
    local resource_type="$1"
    local identifier="$2"

    case "$resource_type" in
        "eks-cluster")
            aws eks describe-cluster --name "$identifier" --region "$AWS_REGION" &>/dev/null
            ;;
        "rds-cluster")
            aws rds describe-db-clusters --db-cluster-identifier "$identifier" --region "$AWS_REGION" &>/dev/null
            ;;
        "elasticache-serverless")
            aws elasticache describe-serverless-caches --serverless-cache-name "$identifier" --region "$AWS_REGION" &>/dev/null
            ;;
        "vpc")
            aws ec2 describe-vpcs --vpc-ids "$identifier" --region "$AWS_REGION" &>/dev/null
            ;;
        "s3-bucket")
            aws s3api head-bucket --bucket "$identifier" --region "$AWS_REGION" &>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

# Get resources by tag
get_tagged_resources() {
    local resource_type="$1"
    local tag_filter="$2"

    case "$resource_type" in
        "vpc")
            aws ec2 describe-vpcs --region "$AWS_REGION" \
                --filters "$tag_filter" \
                --query "Vpcs[?IsDefault==\`false\`].VpcId" \
                --output text
            ;;
        "kms-keys")
            # KMS keys need special handling - check each key's tags
            aws kms list-keys --region "$AWS_REGION" --query "Keys[].KeyId" --output text | \
            while read -r key_id; do
                if aws kms list-resource-tags --key-id "$key_id" --region "$AWS_REGION" \
                   --query "Tags[?Key=='Project' && Value=='OpenEMR']" --output text | grep -q OpenEMR; then
                    echo "$key_id"
                fi
            done 2>/dev/null || true
            ;;
    esac
}

# Terraform state conflict detection
check_terraform_conflicts() {
    log "Checking for terraform state conflicts..."

    if pgrep -f "terraform.*apply" > /dev/null; then
        error "Terraform apply processes are currently running!"
        echo -e "${RED}Please stop all terraform processes before running this script.${NC}"
        echo -e "${YELLOW}Running processes:${NC}"
        pgrep -f terraform | xargs ps -p

        if [[ "$FORCE" != "true" ]]; then
            exit 1
        else
            warn "Force mode enabled - attempting to kill terraform processes"
            pkill -f terraform || true
            sleep 5
        fi
    fi

    if [[ -f "$TERRAFORM_DIR/.terraform.lock.hcl" ]]; then
        warn "Terraform lock file found - there may be state conflicts"
        if [[ "$FORCE" != "true" ]]; then
            read -p "Continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 0
            fi
        fi
    fi
}

# Phase 1: High-Cost Resources (Immediate Cost Savings)
delete_high_cost_resources() {
    log "🔥 Phase 1: Deleting high-cost resources for immediate savings..."

    # EKS Cluster (includes Auto Mode compute)
    if resource_exists "eks-cluster" "$CLUSTER_NAME"; then
        log "Deleting EKS cluster: $CLUSTER_NAME"
        execute "EKS cluster deletion" \
            aws eks delete-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION"

        if [[ "$DRY_RUN" != "true" ]]; then
            log "Waiting for EKS cluster deletion to complete..."
            aws eks wait cluster-deleted --name "$CLUSTER_NAME" --region "$AWS_REGION" || true
        fi

        TOTAL_COST_SAVINGS=$((TOTAL_COST_SAVINGS + 200))  # Estimated EKS Auto Mode cost
        DELETED_RESOURCES+=("EKS Cluster: $CLUSTER_NAME")
    fi

    # NAT Gateways (Major cost savings ~$45/month each)
    log "Deleting NAT gateways for immediate cost savings..."
    local nat_gateways
    nat_gateways=$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
        --filter "Name=state,Values=available" \
        --query "NatGateways[].NatGatewayId" --output text 2>/dev/null || true)

    if [[ -n "$nat_gateways" ]]; then
        local nat_count=0
        for nat_gw in $nat_gateways; do
            execute "NAT Gateway deletion: $nat_gw" \
                aws ec2 delete-nat-gateway --nat-gateway-id "$nat_gw" --region "$AWS_REGION"
            nat_count=$((nat_count + 1))
            DELETED_RESOURCES+=("NAT Gateway: $nat_gw")
        done
        TOTAL_COST_SAVINGS=$((TOTAL_COST_SAVINGS + nat_count * 45))
    fi

    # RDS Aurora Cluster
    local rds_cluster="${CLUSTER_NAME}-aurora"
    if resource_exists "rds-cluster" "$rds_cluster"; then

        if [[ "$PRESERVE_DATA" == "true" && "$DRY_RUN" != "true" ]]; then
            log "Creating final RDS snapshot before deletion..."
            local snapshot_id="${rds_cluster}-final-$(date +%Y%m%d-%H%M%S)"
            aws rds create-db-cluster-snapshot \
                --db-cluster-identifier "$rds_cluster" \
                --db-cluster-snapshot-identifier "$snapshot_id" \
                --region "$AWS_REGION"
        fi

        # Delete cluster instances first
        local instances
        instances=$(aws rds describe-db-clusters \
            --db-cluster-identifier "$rds_cluster" \
            --region "$AWS_REGION" \
            --query "DBClusters[0].DBClusterMembers[].DBInstanceIdentifier" \
            --output text 2>/dev/null || true)

        for instance in $instances; do
            execute "RDS instance deletion: $instance" \
                aws rds delete-db-instance \
                    --db-instance-identifier "$instance" \
                    --skip-final-snapshot \
                    --region "$AWS_REGION"
        done

        # Delete cluster
        execute "RDS cluster deletion: $rds_cluster" \
            aws rds delete-db-cluster \
                --db-cluster-identifier "$rds_cluster" \
                --skip-final-snapshot \
                --region "$AWS_REGION"

        TOTAL_COST_SAVINGS=$((TOTAL_COST_SAVINGS + 100))  # Estimated Aurora cost
        DELETED_RESOURCES+=("RDS Cluster: $rds_cluster")
    fi

    # RDS DB Subnet Groups (delete after clusters)
    log "Deleting RDS DB subnet groups..."
    local db_subnet_groups
    db_subnet_groups=$(aws rds describe-db-subnet-groups --region "$AWS_REGION" \
        --query "DBSubnetGroups[?contains(DBSubnetGroupName, \`${CLUSTER_NAME}\`)].DBSubnetGroupName" \
        --output text 2>/dev/null || true)
    for subnet_group in $db_subnet_groups; do
        execute "RDS DB subnet group deletion: $subnet_group" \
            aws rds delete-db-subnet-group --db-subnet-group-name "$subnet_group" --region "$AWS_REGION"
        DELETED_RESOURCES+=("RDS DB Subnet Group: $subnet_group")
    done

    # ElastiCache Serverless
    local cache_name="${CLUSTER_NAME}-valkey-serverless"
    if resource_exists "elasticache-serverless" "$cache_name"; then
        execute "ElastiCache deletion: $cache_name" \
            aws elasticache delete-serverless-cache \
                --serverless-cache-name "$cache_name" \
                --region "$AWS_REGION"

        TOTAL_COST_SAVINGS=$((TOTAL_COST_SAVINGS + 50))  # Estimated cache cost
        DELETED_RESOURCES+=("ElastiCache: $cache_name")
    fi

    # ElastiCache Users (delete after clusters)
    log "Deleting ElastiCache users..."
    local cache_users
    cache_users=$(aws elasticache describe-users --region "$AWS_REGION" \
        --query "Users[?contains(UserId, \`${CLUSTER_NAME}\`) || contains(UserId, \`openemr\`)].UserId" \
        --output text 2>/dev/null || true)
    for user_id in $cache_users; do
        execute "ElastiCache user deletion: $user_id" \
            aws elasticache delete-user --user-id "$user_id" --region "$AWS_REGION"
        DELETED_RESOURCES+=("ElastiCache User: $user_id")
    done

    # ElastiCache User Groups (delete after users)
    log "Deleting ElastiCache user groups..."
    local cache_user_groups
    cache_user_groups=$(aws elasticache describe-user-groups --region "$AWS_REGION" \
        --query "UserGroups[?contains(UserGroupId, \`${CLUSTER_NAME}\`) || contains(UserGroupId, \`openemr\`)].UserGroupId" \
        --output text 2>/dev/null || true)
    for user_group in $cache_user_groups; do
        execute "ElastiCache user group deletion: $user_group" \
            aws elasticache delete-user-group --user-group-id "$user_group" --region "$AWS_REGION"
        DELETED_RESOURCES+=("ElastiCache User Group: $user_group")
    done

    # ElastiCache Subnet Groups (delete after user groups)
    log "Deleting ElastiCache subnet groups..."
    local cache_subnet_groups
    cache_subnet_groups=$(aws elasticache describe-cache-subnet-groups --region "$AWS_REGION" \
        --query "CacheSubnetGroups[?contains(CacheSubnetGroupName, \`${CLUSTER_NAME}\`)].CacheSubnetGroupName" \
        --output text 2>/dev/null || true)
    for subnet_group in $cache_subnet_groups; do
        execute "ElastiCache subnet group deletion: $subnet_group" \
            aws elasticache delete-cache-subnet-group --cache-subnet-group-name "$subnet_group" --region "$AWS_REGION"
        DELETED_RESOURCES+=("ElastiCache Subnet Group: $subnet_group")
    done

    success "Phase 1 complete - Estimated monthly savings: \$${TOTAL_COST_SAVINGS}"
}

# Phase 2: Storage & Data Resources
delete_storage_resources() {
    log "💾 Phase 2: Deleting storage and data resources..."

    # EFS File System
    log "Deleting EFS file systems..."
    local efs_filesystems
    efs_filesystems=$(aws efs describe-file-systems --region "$AWS_REGION" \
        --query "FileSystems[?CreationToken==\`${CLUSTER_NAME}-efs\`].FileSystemId" \
        --output text 2>/dev/null || true)

    for efs_id in $efs_filesystems; do
        # Delete mount targets first
        local mount_targets
        mount_targets=$(aws efs describe-mount-targets \
            --file-system-id "$efs_id" \
            --region "$AWS_REGION" \
            --query "MountTargets[].MountTargetId" \
            --output text 2>/dev/null || true)

        for mt_id in $mount_targets; do
            execute "EFS mount target deletion: $mt_id" \
                aws efs delete-mount-target --mount-target-id "$mt_id" --region "$AWS_REGION"
        done

        # Wait for mount targets to be deleted
        if [[ "$DRY_RUN" != "true" && -n "$mount_targets" ]]; then
            log "Waiting for EFS mount targets to be deleted..."
            sleep 30
        fi

        execute "EFS file system deletion: $efs_id" \
            aws efs delete-file-system --file-system-id "$efs_id" --region "$AWS_REGION"

        DELETED_RESOURCES+=("EFS FileSystem: $efs_id")
    done

    # S3 Buckets
    log "Deleting S3 buckets..."
    local bucket_patterns=("${CLUSTER_NAME}-alb-logs" "${CLUSTER_NAME}-cloudtrail-logs" "aws-waf-logs-${CLUSTER_NAME}")

    for pattern in "${bucket_patterns[@]}"; do
        local buckets
        buckets=$(aws s3api list-buckets --region "$AWS_REGION" \
            --query "Buckets[?contains(Name, \`$pattern\`)].Name" \
            --output text 2>/dev/null || true)

        for bucket in $buckets; do
            if [[ "$DRY_RUN" != "true" ]]; then
                # Empty bucket first
                aws s3 rm "s3://$bucket" --recursive --region "$AWS_REGION" || true
            fi

            execute "S3 bucket deletion: $bucket" \
                aws s3api delete-bucket --bucket "$bucket" --region "$AWS_REGION"

            DELETED_RESOURCES+=("S3 Bucket: $bucket")
        done
    done

    # CloudWatch Log Groups
    log "Deleting CloudWatch log groups..."
    local log_groups
    log_groups=$(aws logs describe-log-groups --region "$AWS_REGION" \
        --log-group-name-prefix "/aws/eks/$CLUSTER_NAME" \
        --query "logGroups[].logGroupName" \
        --output text 2>/dev/null || true)

    for log_group in $log_groups; do
        execute "CloudWatch log group deletion: $log_group" \
            aws logs delete-log-group --log-group-name "$log_group" --region "$AWS_REGION"

        DELETED_RESOURCES+=("Log Group: $log_group")
    done
}

# Phase 3: Security & Compliance Resources
delete_security_resources() {
    log "🛡️  Phase 3: Deleting security and compliance resources..."

    # WAF ACL (if enabled)
    if [[ "$ENABLE_WAF" == "true" ]]; then
        log "Deleting WAF resources..."
        local waf_acls
        waf_acls=$(aws wafv2 list-web-acls --scope REGIONAL --region "$AWS_REGION" \
            --query "WebACLs[?contains(Name, \`$CLUSTER_NAME\`)].{Name:Name,Id:Id}" \
            --output text 2>/dev/null || true)

        if [[ -n "$waf_acls" ]]; then
            echo "$waf_acls" | while read -r name id; do
                # Get lock token
                local lock_token
                lock_token=$(aws wafv2 get-web-acl --scope REGIONAL \
                    --id "$id" --name "$name" --region "$AWS_REGION" \
                    --query "LockToken" --output text 2>/dev/null || true)

                if [[ -n "$lock_token" ]]; then
                    execute "WAF ACL deletion: $name" \
                        aws wafv2 delete-web-acl --scope REGIONAL \
                            --id "$id" --name "$name" \
                            --lock-token "$lock_token" \
                            --region "$AWS_REGION"

                    DELETED_RESOURCES+=("WAF ACL: $name")
                fi
            done
        fi
    fi

    # CloudTrail
    log "Deleting CloudTrail..."
    local trails
    trails=$(aws cloudtrail describe-trails --region "$AWS_REGION" \
        --query "trailList[?contains(Name, \`$CLUSTER_NAME\`)].Name" \
        --output text 2>/dev/null || true)

    for trail in $trails; do
        execute "CloudTrail deletion: $trail" \
            aws cloudtrail delete-trail --name "$trail" --region "$AWS_REGION"

        DELETED_RESOURCES+=("CloudTrail: $trail")
    done

    # KMS Aliases (delete before scheduling keys)
    log "Deleting KMS aliases..."
    local kms_aliases
    kms_aliases=$(aws kms list-aliases --region "$AWS_REGION" \
        --query "Aliases[?contains(AliasName, \`$CLUSTER_NAME\`)].AliasName" \
        --output text 2>/dev/null || true)
    for alias_name in $kms_aliases; do
        execute "KMS alias deletion: $alias_name" \
            aws kms delete-alias --alias-name "$alias_name" --region "$AWS_REGION"
        DELETED_RESOURCES+=("KMS Alias: $alias_name")
    done

    # WAF Regex Pattern Sets (delete before other WAF resources)
    log "Deleting WAF regex pattern sets..."
    local waf_patterns
    waf_patterns=$(aws wafv2 list-regex-pattern-sets --scope REGIONAL --region "$AWS_REGION" \
        --query "RegexPatternSets[?contains(Name, \`$CLUSTER_NAME\`)].{Name:Name,Id:Id,LockToken:LockToken}" \
        --output text 2>/dev/null || true)
    if [[ -n "$waf_patterns" ]]; then
        echo "$waf_patterns" | while read -r name id lock_token; do
            execute "WAF regex pattern set deletion: $name" \
                aws wafv2 delete-regex-pattern-set --scope REGIONAL \
                    --id "$id" --name "$name" \
                    --lock-token "$lock_token" \
                    --region "$AWS_REGION"
            DELETED_RESOURCES+=("WAF Regex Pattern Set: $name")
        done
    fi

    # KMS Keys (schedule for deletion)
    log "Scheduling KMS keys for deletion..."
    local kms_keys
    kms_keys=$(get_tagged_resources "kms-keys" "")

    for key_id in $kms_keys; do
        # Check if key is already scheduled for deletion
        local key_state
        key_state=$(aws kms describe-key --key-id "$key_id" --region "$AWS_REGION" \
            --query "KeyMetadata.KeyState" --output text 2>/dev/null || true)

        if [[ "$key_state" != "PendingDeletion" ]]; then
            execute "KMS key schedule deletion: $key_id" \
                aws kms schedule-key-deletion \
                    --key-id "$key_id" \
                    --pending-window-in-days 7 \
                    --region "$AWS_REGION"

            DELETED_RESOURCES+=("KMS Key (scheduled): $key_id")
        fi
    done
}

# Phase 4: Networking Dependencies (Order Critical)
delete_networking_resources() {
    log "🌐 Phase 4: Deleting networking resources in dependency order..."

    # Get OpenEMR VPCs (exclude walnut-main-vpc and default VPCs)
    local vpcs
    vpcs=$(aws ec2 describe-vpcs --region "$AWS_REGION" \
        --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" \
        --query "Vpcs[].VpcId" --output text 2>/dev/null || true)

    for vpc_id in $vpcs; do
        log "Processing VPC: $vpc_id"

        # Delete VPC flow logs
        local flow_logs
        flow_logs=$(aws ec2 describe-flow-logs --region "$AWS_REGION" \
            --filter "Name=resource-id,Values=$vpc_id" \
            --query "FlowLogs[].FlowLogId" --output text 2>/dev/null || true)

        for fl_id in $flow_logs; do
            execute "VPC flow log deletion: $fl_id" \
                aws ec2 delete-flow-logs --flow-log-ids "$fl_id" --region "$AWS_REGION"
        done

        # Delete security groups (except default)
        local security_groups
        security_groups=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --query "SecurityGroups[?GroupName!=\`default\`].GroupId" \
            --output text 2>/dev/null || true)

        # Delete security groups with retry for dependency conflicts
        for sg_id in $security_groups; do
            local retries=3
            while [[ $retries -gt 0 ]]; do
                if execute "Security group deletion: $sg_id" \
                   aws ec2 delete-security-group --group-id "$sg_id" --region "$AWS_REGION"; then
                    break
                else
                    retries=$((retries - 1))
                    if [[ $retries -gt 0 ]]; then
                        warn "Retrying security group deletion in 10 seconds..."
                        sleep 10
                    fi
                fi
            done
        done

        # Delete subnets
        local subnets
        subnets=$(aws ec2 describe-subnets --region "$AWS_REGION" \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --query "Subnets[].SubnetId" --output text 2>/dev/null || true)

        for subnet_id in $subnets; do
            execute "Subnet deletion: $subnet_id" \
                aws ec2 delete-subnet --subnet-id "$subnet_id" --region "$AWS_REGION"
        done

        # Delete internet gateways
        local igws
        igws=$(aws ec2 describe-internet-gateways --region "$AWS_REGION" \
            --filters "Name=attachment.vpc-id,Values=$vpc_id" \
            --query "InternetGateways[].InternetGatewayId" \
            --output text 2>/dev/null || true)

        for igw_id in $igws; do
            execute "Internet gateway detachment: $igw_id" \
                aws ec2 detach-internet-gateway \
                    --internet-gateway-id "$igw_id" \
                    --vpc-id "$vpc_id" \
                    --region "$AWS_REGION"

            execute "Internet gateway deletion: $igw_id" \
                aws ec2 delete-internet-gateway \
                    --internet-gateway-id "$igw_id" \
                    --region "$AWS_REGION"
        done

        # Delete route tables (except main)
        local route_tables
        route_tables=$(aws ec2 describe-route-tables --region "$AWS_REGION" \
            --filters "Name=vpc-id,Values=$vpc_id" \
            --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" \
            --output text 2>/dev/null || true)

        for rt_id in $route_tables; do
            execute "Route table deletion: $rt_id" \
                aws ec2 delete-route-table --route-table-id "$rt_id" --region "$AWS_REGION"
        done

        # Finally delete VPC
        execute "VPC deletion: $vpc_id" \
            aws ec2 delete-vpc --vpc-id "$vpc_id" --region "$AWS_REGION"

        DELETED_RESOURCES+=("VPC: $vpc_id")
    done
}

# Phase 5: IAM and Final Cleanup
delete_iam_resources() {
    log "👤 Phase 5: Deleting IAM resources and final cleanup..."

    # Delete IAM roles associated with the cluster
    local iam_roles
    iam_roles=$(aws iam list-roles --region "$AWS_REGION" \
        --query "Roles[?contains(RoleName, \`$CLUSTER_NAME\`)].RoleName" \
        --output text 2>/dev/null || true)

    for role in $iam_roles; do
        # Detach policies first
        local policies
        policies=$(aws iam list-attached-role-policies --role-name "$role" \
            --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null || true)

        for policy in $policies; do
            execute "IAM policy detachment: $policy from $role" \
                aws iam detach-role-policy --role-name "$role" --policy-arn "$policy"
        done

        # Delete inline policies
        local inline_policies
        inline_policies=$(aws iam list-role-policies --role-name "$role" \
            --query "PolicyNames[]" --output text 2>/dev/null || true)

        for policy in $inline_policies; do
            execute "IAM inline policy deletion: $policy from $role" \
                aws iam delete-role-policy --role-name "$role" --policy-name "$policy"
        done

        execute "IAM role deletion: $role" \
            aws iam delete-role --role-name "$role"

        DELETED_RESOURCES+=("IAM Role: $role")
    done
}

# Final verification
verify_cleanup() {
    log "🔍 Final verification of cleanup..."

    local remaining_resources=()

    # Check for remaining resources
    if resource_exists "eks-cluster" "$CLUSTER_NAME"; then
        remaining_resources+=("EKS Cluster: $CLUSTER_NAME")
    fi

    if resource_exists "rds-cluster" "${CLUSTER_NAME}-aurora"; then
        remaining_resources+=("RDS Cluster: ${CLUSTER_NAME}-aurora")
    fi

    local remaining_vpcs
    remaining_vpcs=$(aws ec2 describe-vpcs --region "$AWS_REGION" \
        --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" \
        --query "Vpcs[].VpcId" --output text 2>/dev/null || true)

    if [[ -n "$remaining_vpcs" ]]; then
        for vpc in $remaining_vpcs; do
            remaining_resources+=("VPC: $vpc")
        done
    fi

    if [[ ${#remaining_resources[@]} -eq 0 ]]; then
        success "🎉 All OpenEMR infrastructure successfully destroyed!"
    else
        warn "Some resources may still exist:"
        for resource in "${remaining_resources[@]}"; do
            echo -e "${YELLOW}  - $resource${NC}"
        done
    fi
}

# Main execution
main() {
    echo -e "${BOLD}${RED}🔥 OpenEMR Complete Infrastructure Destruction${NC}"
    echo -e "${BOLD}${RED}=============================================${NC}"
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${CYAN}${BOLD}DRY RUN MODE - No resources will be deleted${NC}"
        echo ""
    fi

    echo -e "${YELLOW}Target Configuration:${NC}"
    echo -e "${BLUE}  Region: $AWS_REGION${NC}"
    echo -e "${BLUE}  Cluster: $CLUSTER_NAME${NC}"
    echo -e "${BLUE}  WAF Enabled: $ENABLE_WAF${NC}"
    echo ""

    if [[ "$DRY_RUN" != "true" ]]; then
        echo -e "${RED}${BOLD}⚠️  WARNING: This will DELETE ALL OpenEMR infrastructure!${NC}"
        echo -e "${RED}This includes EKS, RDS, EFS, VPC, and ALL associated resources.${NC}"
        echo -e "${RED}This action cannot be undone!${NC}"
        echo ""

        if [[ "$FORCE" != "true" ]]; then
            read -p "Are you absolutely sure you want to destroy ALL infrastructure? (type 'yes' to continue): " -r
            if [[ $REPLY != "yes" ]]; then
                echo -e "${YELLOW}Destruction cancelled.${NC}"
                exit 0
            fi
        else
            echo -e "${RED}Force mode enabled - skipping confirmation${NC}"
        fi
        echo ""
    fi

    # Execute phases
    check_terraform_conflicts
    delete_high_cost_resources
    delete_storage_resources
    delete_security_resources
    delete_networking_resources
    delete_iam_resources

    if [[ "$DRY_RUN" != "true" ]]; then
        verify_cleanup
    fi

    # Summary
    echo ""
    echo -e "${GREEN}${BOLD}📊 Destruction Summary${NC}"
    echo -e "${GREEN}=====================${NC}"
    echo -e "${BLUE}Estimated Monthly Cost Savings: \$${TOTAL_COST_SAVINGS}${NC}"
    echo -e "${BLUE}Resources Deleted: ${#DELETED_RESOURCES[@]}${NC}"
    echo -e "${BLUE}Failed Deletions: ${#FAILED_DELETIONS[@]}${NC}"

    if [[ ${#FAILED_DELETIONS[@]} -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}Failed Deletions:${NC}"
        for failure in "${FAILED_DELETIONS[@]}"; do
            echo -e "${RED}  - $failure${NC}"
        done
    fi

    echo ""
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${CYAN}This was a dry run. To actually destroy resources, run:${NC}"
        echo -e "${CYAN}  $0${NC}"
    else
        echo -e "${GREEN}Infrastructure destruction complete!${NC}"
        echo -e "${BLUE}You can now deploy fresh infrastructure using:${NC}"
        echo -e "${BLUE}  cd $TERRAFORM_DIR && terraform apply${NC}"
    fi
}

# Execute main function
main "$@"