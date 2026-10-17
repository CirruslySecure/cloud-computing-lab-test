#!/bin/bash
set -e
export $(grep -v '^#' .env | xargs)
echo "== S3 bucket =="
if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null; then
echo "Bucket already exists, skipping."
else
aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
--create-bucket-configuration LocationConstraint="$AWS_REGION"
fi
cat > trust-policy.json << 'EOF'
{ "Version": "2012-10-17", "Statement": [
{ "Effect": "Allow", "Principal": { "Service": "ec2.amazonaws.com" }, "Action": "sts:AssumeRole" } ] }
EOF
echo "== Uploader role (PutObject on shared.txt only) =="
aws iam create-role --role-name "$UPLOADER_ROLE_NAME" \
--assume-role-policy-document file://trust-policy.json 2>/dev/null || echo "Role exists, skipping."
cat > uploader-policy.json << EOF
{ "Version": "2012-10-17", "Statement": [
{ "Effect": "Allow", "Action": ["s3:PutObject"], "Resource": "arn:aws:s3:::${BUCKET_NAME}/shared.txt" } ] }
EOF
aws iam put-role-policy --role-name "$UPLOADER_ROLE_NAME" \
--policy-name "${UPLOADER_ROLE_NAME}-policy" --policy-document file://uploader-policy.json
aws iam create-instance-profile --instance-profile-name "$UPLOADER_PROFILE_NAME" 2>/dev/null || echo "Profile
exists, skipping."
aws iam add-role-to-instance-profile --instance-profile-name "$UPLOADER_PROFILE_NAME" \
--role-name "$UPLOADER_ROLE_NAME" 2>/dev/null || true
echo "== Viewer role (GetObject + ListBucket on shared.txt only) =="
aws iam create-role --role-name "$VIEWER_ROLE_NAME" \
--assume-role-policy-document file://trust-policy.json 2>/dev/null || echo "Role exists, skipping."
cat > viewer-policy.json << EOF
{ "Version": "2012-10-17", "Statement": [
{ "Effect": "Allow", "Action": ["s3:GetObject"], "Resource": "arn:aws:s3:::${BUCKET_NAME}/shared.txt" },
{ "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::${BUCKET_NAME}" } ] }
EOF
aws iam put-role-policy --role-name "$VIEWER_ROLE_NAME" \
--policy-name "${VIEWER_ROLE_NAME}-policy" --policy-document file://viewer-policy.json
aws iam create-instance-profile --instance-profile-name "$VIEWER_PROFILE_NAME" 2>/dev/null || echo "Profile
exists, skipping."
aws iam add-role-to-instance-profile --instance-profile-name "$VIEWER_PROFILE_NAME" \
--role-name "$VIEWER_ROLE_NAME" 2>/dev/null || true
echo "Waiting 15s for IAM propagation..."
sleep 15
echo "== Building user-data from local lab03/ files =="
UPLOADER_APP_JS_B64=$(base64 -w0 lab03/uploader-app/app.js)
UPLOADER_PKG_JSON_B64=$(base64 -w0 lab03/uploader-app/package.json)
cat > user-data-uploader.sh << EOF
#!/bin/bash
dnf update -y
dnf install -y nodejs
mkdir -p /opt/app
echo "$UPLOADER_APP_JS_B64" | base64 -d > /opt/app/app.js
echo "$UPLOADER_PKG_JSON_B64" | base64 -d > /opt/app/package.json
cd /opt/app
npm install --omit=dev
cat > /etc/systemd/system/uploader.service << 'SERVICE'
[Unit]
Description=Uploader App
After=network.target
[Service]
Environment=BUCKET_NAME=$BUCKET_NAME
Environment=AWS_REGION=$AWS_REGION
Environment=PORT=3000
WorkingDirectory=/opt/app
ExecStart=/usr/bin/node /opt/app/app.js
Restart=always
User=ec2-user
[Install]
WantedBy=multi-user.target
SERVICE
chown -R ec2-user:ec2-user /opt/app
systemctl daemon-reload
systemctl enable uploader.service
systemctl start uploader.service
EOF
VIEWER_APP_JS_B64=$(base64 -w0 lab03/viewer-app/app.js)
VIEWER_PKG_JSON_B64=$(base64 -w0 lab03/viewer-app/package.json)
cat > user-data-viewer.sh << EOF
#!/bin/bash
dnf update -y
dnf install -y nodejs
mkdir -p /opt/app
echo "$VIEWER_APP_JS_B64" | base64 -d > /opt/app/app.js
echo "$VIEWER_PKG_JSON_B64" | base64 -d > /opt/app/package.json
cd /opt/app
npm install --omit=dev
cat > /etc/systemd/system/viewer.service << 'SERVICE'
[Unit]
Description=Viewer App
After=network.target
[Service]
Environment=BUCKET_NAME=$BUCKET_NAME
Environment=AWS_REGION=$AWS_REGION
Environment=PORT=3000
WorkingDirectory=/opt/app
ExecStart=/usr/bin/node /opt/app/app.js
Restart=always
User=ec2-user
[Install]
WantedBy=multi-user.target
SERVICE
chown -R ec2-user:ec2-user /opt/app
systemctl daemon-reload
systemctl enable viewer.service
systemctl start viewer.service
EOF
echo "== Building launch template data =="
UPLOADER_USERDATA_B64=$(base64 -w0 user-data-uploader.sh)
VIEWER_USERDATA_B64=$(base64 -w0 user-data-viewer.sh)
cat > uploader-lt-data.json << EOF
{
"ImageId": "$AMI_ID",
"InstanceType": "$INSTANCE_TYPE",
"KeyName": "$KEY_NAME",
"SecurityGroupIds": ["$APP_SECURITY_GROUP_ID"],
"IamInstanceProfile": { "Name": "$UPLOADER_PROFILE_NAME" },
"UserData": "$UPLOADER_USERDATA_B64",
"TagSpecifications": [
{ "ResourceType": "instance", "Tags": [{ "Key": "Name", "Value": "uploader-app" }] }
]
}
EOF
cat > viewer-lt-data.json << EOF
{
"ImageId": "$AMI_ID",
"InstanceType": "$INSTANCE_TYPE",
"KeyName": "$KEY_NAME",
"SecurityGroupIds": ["$APP_SECURITY_GROUP_ID"],
"IamInstanceProfile": { "Name": "$VIEWER_PROFILE_NAME" },
"UserData": "$VIEWER_USERDATA_B64",
"TagSpecifications": [
{ "ResourceType": "instance", "Tags": [{ "Key": "Name", "Value": "viewer-app" }] }
]
}
EOF
echo "== Creating/updating launch templates =="
if aws ec2 describe-launch-templates --launch-template-names "$UPLOADER_LT_NAME" --region "$AWS_REGION">/dev/null 2>&1; then
echo "Template $UPLOADER_LT_NAME exists — publishing a new version"
aws ec2 create-launch-template-version \
--launch-template-name "$UPLOADER_LT_NAME" \
--source-version 1 \
--launch-template-data file://uploader-lt-data.json \
--region "$AWS_REGION" > /dev/null
else
aws ec2 create-launch-template \
--launch-template-name "$UPLOADER_LT_NAME" \
--launch-template-data file://uploader-lt-data.json \
--region "$AWS_REGION" > /dev/null
fi
if aws ec2 describe-launch-templates --launch-template-names "$VIEWER_LT_NAME" --region "$AWS_REGION">/dev/null 2>&1; then
echo "Template $VIEWER_LT_NAME exists — publishing a new version"
aws ec2 create-launch-template-version \
--launch-template-name "$VIEWER_LT_NAME" \
--source-version 1 \
--launch-template-data file://viewer-lt-data.json \
--region "$AWS_REGION" > /dev/null
else
aws ec2 create-launch-template \
--launch-template-name "$VIEWER_LT_NAME" \
--launch-template-data file://viewer-lt-data.json \
--region "$AWS_REGION" > /dev/null
fi

echo "== Looking up VPC and subnets =="
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text --region "$AWS_REGION")

SUBNET_A=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$AZ_A" \
    --query "Subnets[0].SubnetId" \
    --output text --region "$AWS_REGION")

SUBNET_B=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$AZ_B" \
    --query "Subnets[0].SubnetId" \
    --output text --region "$AWS_REGION")

if [[ "$VPC_ID" == "None" || "$SUBNET_A" == "None" || "$SUBNET_B" == "None" ]]; then
    echo "ERROR: VPC or subnet lookup failed."
    exit 1
fi

APP_VPC_ID=$(aws ec2 describe-security-groups \
    --group-ids "$APP_SECURITY_GROUP_ID" \
    --query "SecurityGroups[0].VpcId" \
    --output text --region "$AWS_REGION")

if [[ "$APP_VPC_ID" != "$VPC_ID" ]]; then
    echo "ERROR: Application security group is in a different VPC."
    exit 1
fi

echo "== Creating ALB security group =="
ALB_SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$ALB_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[0].GroupId" \
    --output text --region "$AWS_REGION")

if [[ "$ALB_SECURITY_GROUP_ID" == "None" ]]; then
    ALB_SECURITY_GROUP_ID=$(aws ec2 create-security-group \
        --group-name "$ALB_SG_NAME" \
        --description "Application Load Balancer security group" \
        --vpc-id "$VPC_ID" \
        --query "GroupId" \
        --output text --region "$AWS_REGION")
fi

for PORT in "$UPLOADER_LISTENER_PORT" "$VIEWER_LISTENER_PORT"; do
    aws ec2 authorize-security-group-ingress \
        --group-id "$ALB_SECURITY_GROUP_ID" \
        --protocol tcp --port "$PORT" \
        --cidr 0.0.0.0/0 \
        --region "$AWS_REGION" >/dev/null 2>&1 || true
done

echo "== Tightening the app security group to only accept traffic from the ALB =="
aws ec2 revoke-security-group-ingress --group-id "$APP_SECURITY_GROUP_ID" \
    --protocol tcp --port 3000 --cidr 0.0.0.0/0 --region "$AWS_REGION" >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$APP_SECURITY_GROUP_ID" \
    --protocol tcp --port 3000 --source-group "$ALB_SECURITY_GROUP_ID" --region "$AWS_REGION" >/dev/null 2>&1 || true

echo "== Creating target groups =="
create_target_group() {
    local NAME="$1"
    local ARN

    ARN=$(aws elbv2 describe-target-groups \
        --names "$NAME" \
        --query "TargetGroups[0].TargetGroupArn" \
        --output text --region "$AWS_REGION" 2>/dev/null) || ARN="None"

    if [[ "$ARN" == "None" || -z "$ARN" ]]; then
        ARN=$(aws elbv2 create-target-group \
            --name "$NAME" \
            --protocol HTTP --port 3000 \
            --vpc-id "$VPC_ID" \
            --target-type instance \
            --health-check-protocol HTTP \
            --health-check-path / \
            --health-check-interval-seconds 10 \
            --health-check-timeout-seconds 5 \
            --healthy-threshold-count 2 \
            --unhealthy-threshold-count 2 \
            --query "TargetGroups[0].TargetGroupArn" \
            --output text --region "$AWS_REGION")
    fi

    printf '%s\n' "$ARN"
}

UPLOADER_TG_ARN=$(create_target_group "$UPLOADER_TG_NAME")
VIEWER_TG_ARN=$(create_target_group "$VIEWER_TG_NAME")

echo "== Creating Application Load Balancer =="
ALB_ARN=$(aws elbv2 describe-load-balancers \
    --names "$ALB_NAME" \
    --query "LoadBalancers[0].LoadBalancerArn" \
    --output text --region "$AWS_REGION" 2>/dev/null) || ALB_ARN="None"

if [[ "$ALB_ARN" == "None" || -z "$ALB_ARN" ]]; then
    ALB_ARN=$(aws elbv2 create-load-balancer \
        --name "$ALB_NAME" \
        --subnets "$SUBNET_A" "$SUBNET_B" \
        --security-groups "$ALB_SECURITY_GROUP_ID" \
        --scheme internet-facing \
        --type application \
        --query "LoadBalancers[0].LoadBalancerArn" \
        --output text --region "$AWS_REGION")
fi

aws elbv2 wait load-balancer-available \
    --load-balancer-arns "$ALB_ARN" \
    --region "$AWS_REGION"

echo "== Creating listeners =="
create_listener() {
    local PORT="$1"
    local TARGET_ARN="$2"
    local EXISTING

    EXISTING=$(aws elbv2 describe-listeners \
        --load-balancer-arn "$ALB_ARN" \
        --query "Listeners[?Port==\`$PORT\`].ListenerArn | [0]" \
        --output text --region "$AWS_REGION")

    if [[ "$EXISTING" == "None" || -z "$EXISTING" ]]; then
        aws elbv2 create-listener \
            --load-balancer-arn "$ALB_ARN" \
            --protocol HTTP \
            --port "$PORT" \
            --default-actions "Type=forward,TargetGroupArn=$TARGET_ARN" \
            --region "$AWS_REGION" >/dev/null
    fi
}

create_listener "$UPLOADER_LISTENER_PORT" "$UPLOADER_TG_ARN"
create_listener "$VIEWER_LISTENER_PORT" "$VIEWER_TG_ARN"

ALB_DNS_NAME=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$ALB_ARN" \
    --query "LoadBalancers[0].DNSName" \
    --output text --region "$AWS_REGION")

echo "== Creating Auto Scaling Groups =="
create_asg() {
    local NAME="$1"
    local TEMPLATE="$2"
    local TARGET_ARN="$3"
    local APP_NAME="$4"
    local EXISTING

    EXISTING=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$NAME" \
        --query "AutoScalingGroups[0].AutoScalingGroupName" \
        --output text --region "$AWS_REGION")

    if [[ "$EXISTING" == "None" || -z "$EXISTING" ]]; then
        aws autoscaling create-auto-scaling-group \
            --auto-scaling-group-name "$NAME" \
            --launch-template "LaunchTemplateName=$TEMPLATE,Version=\$Latest" \
            --min-size 1 \
            --max-size 1 \
            --desired-capacity 1 \
            --vpc-zone-identifier "$SUBNET_A,$SUBNET_B" \
            --target-group-arns "$TARGET_ARN" \
            --health-check-type ELB \
            --health-check-grace-period 120 \
            --tags "ResourceId=$NAME,ResourceType=auto-scaling-group,Key=Name,Value=$APP_NAME,PropagateAtLaunch=true" \
            --region "$AWS_REGION"
    else
        echo "Auto Scaling Group $NAME already exists."
    fi
}

create_asg "$UPLOADER_ASG_NAME" "$UPLOADER_LT_NAME" "$UPLOADER_TG_ARN" "uploader-app"
create_asg "$VIEWER_ASG_NAME" "$VIEWER_LT_NAME" "$VIEWER_TG_ARN" "viewer-app"

echo "== Saving stack outputs =="
cat > stack_outputs.env <<OUTPUTS
VPC_ID=$VPC_ID
SUBNET_A=$SUBNET_A
SUBNET_B=$SUBNET_B
ALB_SECURITY_GROUP_ID=$ALB_SECURITY_GROUP_ID
ALB_ARN=$ALB_ARN
ALB_DNS_NAME=$ALB_DNS_NAME
UPLOADER_TG_ARN=$UPLOADER_TG_ARN
VIEWER_TG_ARN=$VIEWER_TG_ARN
OUTPUTS

echo "== Deployment complete =="
echo "Uploader: http://$ALB_DNS_NAME:$UPLOADER_LISTENER_PORT/"
echo "Viewer:   http://$ALB_DNS_NAME:$VIEWER_LISTENER_PORT/"
echo "Wait for both target groups to become healthy."
