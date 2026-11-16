#!/bin/bash
set -e
export $(grep -v '^#' .env | xargs)
if [[ -f uploader_instance_id.txt && -f viewer_instance_id.txt ]]; then
UPLOADER_ID=$(cat uploader_instance_id.txt)
VIEWER_ID=$(cat viewer_instance_id.txt)
echo "Terminating instances: $UPLOADER_ID $VIEWER_ID"
aws ec2 terminate-instances --instance-ids "$UPLOADER_ID" "$VIEWER_ID" --region "$AWS_REGION"
aws ec2 wait instance-terminated --instance-ids "$UPLOADER_ID" "$VIEWER_ID" --region "$AWS_REGION"
echo "Instances terminated."
rm -f uploader_instance_id.txt viewer_instance_id.txt
else
echo "No instance ID files found — skipping instance termination."
fi
echo "== Deleting Auto Scaling Groups =="
for ASG_NAME in "$UPLOADER_ASG_NAME" "$VIEWER_ASG_NAME"; do
    echo "Checking Auto Scaling Group: $ASG_NAME"

    ASG_EXISTS=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$ASG_NAME" \
        --region "$AWS_REGION" \
        --query "AutoScalingGroups[0].AutoScalingGroupName" \
        --output text)

    if [[ "$ASG_EXISTS" != "None" && -n "$ASG_EXISTS" ]]; then
        aws autoscaling update-auto-scaling-group \
            --auto-scaling-group-name "$ASG_NAME" \
            --min-size 0 \
            --desired-capacity 0 \
            --region "$AWS_REGION"

        aws autoscaling delete-auto-scaling-group \
            --auto-scaling-group-name "$ASG_NAME" \
            --force-delete \
            --region "$AWS_REGION"
    fi
done

echo "== Waiting for Auto Scaling Groups to be deleted =="
for ASG_NAME in "$UPLOADER_ASG_NAME" "$VIEWER_ASG_NAME"; do
    for ATTEMPT in {1..60}; do
        ASG_STATUS=$(aws autoscaling describe-auto-scaling-groups \
            --auto-scaling-group-names "$ASG_NAME" \
            --region "$AWS_REGION" \
            --query "AutoScalingGroups[0].AutoScalingGroupName" \
            --output text)

        if [[ "$ASG_STATUS" == "None" || -z "$ASG_STATUS" ]]; then
            echo "Deleted: $ASG_NAME"
            break
        fi

        if [[ "$ATTEMPT" -eq 60 ]]; then
            echo "ERROR: Timed out waiting for $ASG_NAME to be deleted."
            exit 1
        fi

        sleep 10
    done
done

echo "== Deleting Application Load Balancer =="
ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names "$ALB_NAME" \
    --region "$AWS_REGION" \
    --query "LoadBalancers[0].LoadBalancerArn" \
    --output text 2>/dev/null) || ALB_ARN="None"

if [[ "$ALB_ARN" != "None" && -n "$ALB_ARN" ]]; then
    aws elbv2 delete-load-balancer \
        --load-balancer-arn "$ALB_ARN" \
        --region "$AWS_REGION"

    aws elbv2 wait load-balancers-deleted \
        --load-balancer-arns "$ALB_ARN" \
        --region "$AWS_REGION"
fi

echo "== Deleting target groups =="
for TG_NAME in "$UPLOADER_TG_NAME" "$VIEWER_TG_NAME"; do
    TG_ARN=$(aws elbv2 describe-target-groups \
        --names "$TG_NAME" \
        --region "$AWS_REGION" \
        --query "TargetGroups[0].TargetGroupArn" \
        --output text 2>/dev/null) || TG_ARN="None"

    if [[ "$TG_ARN" != "None" && -n "$TG_ARN" ]]; then
        aws elbv2 delete-target-group \
            --target-group-arn "$TG_ARN" \
            --region "$AWS_REGION"
    fi
done

echo "== Deleting ALB security group =="
VPC_ID=$(aws ec2 describe-security-groups \
    --group-ids "$APP_SECURITY_GROUP_ID" \
    --region "$AWS_REGION" \
    --query "SecurityGroups[0].VpcId" \
    --output text)

ALB_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$ALB_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --region "$AWS_REGION" \
    --query "SecurityGroups[0].GroupId" \
    --output text)

if [[ "$ALB_SG_ID" != "None" && -n "$ALB_SG_ID" ]]; then
    aws ec2 revoke-security-group-ingress \
        --group-id "$APP_SECURITY_GROUP_ID" \
        --protocol tcp \
        --port 3000 \
        --source-group "$ALB_SG_ID" \
        --region "$AWS_REGION" 2>/dev/null || true

    aws ec2 delete-security-group \
        --group-id "$ALB_SG_ID" \
        --region "$AWS_REGION"
fi

rm -f stack_outputs.env

echo "== Deleting launch templates =="
aws ec2 delete-launch-template --launch-template-name "$UPLOADER_LT_NAME" --region "$AWS_REGION" 2>/dev/null || true
aws ec2 delete-launch-template --launch-template-name "$VIEWER_LT_NAME" --region "$AWS_REGION" 2>/dev/null || true
echo "== Removing IAM instance profiles and roles =="
aws iam remove-role-from-instance-profile --instance-profile-name "$UPLOADER_PROFILE_NAME" \
--role-name "$UPLOADER_ROLE_NAME" 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name "$UPLOADER_PROFILE_NAME" 2>/dev/null || true
aws iam delete-role-policy --role-name "$UPLOADER_ROLE_NAME" \
--policy-name "${UPLOADER_ROLE_NAME}-policy" 2>/dev/null || true
aws iam delete-role --role-name "$UPLOADER_ROLE_NAME" 2>/dev/null || true
aws iam remove-role-from-instance-profile --instance-profile-name "$VIEWER_PROFILE_NAME" \
--role-name "$VIEWER_ROLE_NAME" 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name "$VIEWER_PROFILE_NAME" 2>/dev/null || true
aws iam delete-role-policy --role-name "$VIEWER_ROLE_NAME" \
--policy-name "${VIEWER_ROLE_NAME}-policy" 2>/dev/null || true
aws iam delete-role --role-name "$VIEWER_ROLE_NAME" 2>/dev/null || true
echo "== Emptying and deleting S3 bucket =="
aws s3 rm "s3://$BUCKET_NAME" --recursive --region "$AWS_REGION" 2>/dev/null || true
aws s3api delete-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null || true
echo "Cleanup complete."
