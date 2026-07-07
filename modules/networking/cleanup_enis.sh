#!/bin/bash
set +e  # Don't exit on errors - we want to try cleaning up everything

echo "🧹 Cleaning up orphaned ENIs before subnet deletion..."

REGION="$1"
VPC_ID="$2"

if [ -z "$REGION" ] || [ -z "$VPC_ID" ]; then
  echo "Usage: $0 <region> <vpc_id>"
  exit 1
fi

echo "Region: $REGION, VPC: $VPC_ID"

# First, clean up any Load Balancers in the VPC (they create ENIs)
echo "🔍 Checking for orphaned Load Balancers..."

# Clean up NLBs/ALBs
LBS=$(aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null || echo "")

if [ -n "$LBS" ] && [ "$LBS" != "None" ]; then
  for lb_arn in $LBS; do
    echo "  Deleting Load Balancer: $lb_arn"
    aws elbv2 delete-load-balancer --load-balancer-arn "$lb_arn" --region "$REGION" 2>/dev/null || true
  done
  
  # Wait for LB deletion to complete
  echo "  Waiting for Load Balancers to be fully deleted..."
  sleep 45
fi

# Clean up Classic ELBs
CLASSIC_LBS=$(aws elb describe-load-balancers --region "$REGION" --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text 2>/dev/null || echo "")

if [ -n "$CLASSIC_LBS" ] && [ "$CLASSIC_LBS" != "None" ]; then
  for lb_name in $CLASSIC_LBS; do
    echo "  Deleting Classic Load Balancer: $lb_name"
    aws elb delete-load-balancer --load-balancer-name "$lb_name" --region "$REGION" 2>/dev/null || true
  done
  sleep 15
fi

# Get all ENIs in the VPC
echo "Finding ENIs in VPC $VPC_ID..."

ENIS=$(aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --region "$REGION" \
  --query 'NetworkInterfaces[*].{Id:NetworkInterfaceId,Status:Status,AttachmentId:Attachment.AttachmentId,Description:Description}' \
  --output json 2>/dev/null || echo "[]")

ENI_COUNT=$(echo "$ENIS" | jq 'length' 2>/dev/null || echo "0")
echo "Found $ENI_COUNT ENIs in VPC"

# Process each ENI
echo "$ENIS" | jq -c '.[]' 2>/dev/null | while read -r eni; do
  eni_id=$(echo "$eni" | jq -r '.Id')
  status=$(echo "$eni" | jq -r '.Status')
  attachment_id=$(echo "$eni" | jq -r '.AttachmentId')
  description=$(echo "$eni" | jq -r '.Description')
  
  # Skip primary ENIs (managed by instances)
  if echo "$description" | grep -qE "Primary network interface|EKS.*managed"; then
    continue
  fi
  
  # Clean up ELB/EKS ENIs and any available ENIs
  should_cleanup=false
  
  if echo "$description" | grep -qE "ELB|load-balancer|eks-cluster|amazon-elb|Amazon EKS"; then
    should_cleanup=true
  elif [ "$status" = "available" ]; then
    should_cleanup=true
  fi
  
  if [ "$should_cleanup" = "true" ]; then
    echo "Processing ENI: $eni_id (Status: $status, Desc: $description)"
    
    # If ENI is attached (in-use), detach it first
    if [ "$status" = "in-use" ] && [ -n "$attachment_id" ] && [ "$attachment_id" != "null" ]; then
      echo "  Detaching ENI $eni_id..."
      aws ec2 detach-network-interface --attachment-id "$attachment_id" --force --region "$REGION" 2>/dev/null || true
      
      # Wait for detachment
      for i in 1 2 3 4 5 6 7 8 9 10; do
        current_status=$(aws ec2 describe-network-interfaces --network-interface-ids "$eni_id" --region "$REGION" --query 'NetworkInterfaces[0].Status' --output text 2>/dev/null || echo "deleted")
        if [ "$current_status" = "available" ] || [ "$current_status" = "deleted" ]; then
          break
        fi
        echo "  Waiting for ENI detachment... ($i/10)"
        sleep 2
      done
    fi
    
    # Delete the ENI
    echo "  Deleting ENI $eni_id..."
    aws ec2 delete-network-interface --network-interface-id "$eni_id" --region "$REGION" 2>/dev/null || true
  fi
done

# Final cleanup pass - get any remaining available ENIs
echo "🔄 Final ENI cleanup pass..."

REMAINING_ENIS=$(aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
  --region "$REGION" \
  --query 'NetworkInterfaces[*].NetworkInterfaceId' \
  --output text 2>/dev/null || echo "")

for eni_id in $REMAINING_ENIS; do
  if [ -n "$eni_id" ] && [ "$eni_id" != "None" ]; then
    echo "  Force deleting remaining ENI: $eni_id"
    aws ec2 delete-network-interface --network-interface-id "$eni_id" --region "$REGION" 2>/dev/null || true
  fi
done

echo "✅ ENI cleanup complete"
exit 0
