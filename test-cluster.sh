#!/bin/sh
#set -x

region=us-east-2
ami_id=''
cleanup_only=''

for arg in "$@"
do
   case "$arg" in
        --region=*)
        region="${1#*=}"
        ;;
        --ami=*)
        ami_id="${1#*=}"
        ;;
        --cleanup)
            cleanup_only='yes'
    esac
    shift
done

echo REGION = $region 
echo AMI = $ami_id
echo DO Cleanup $cleanup_only

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

readonly key_pair_name=eks-key
readonly stack_name=kontain-eks-vpc-stack
readonly cluster_role=kontainAmazonEKSClusterRole
readonly cluster_name=kontain-eks-cluster
readonly node_role=kontainAmazonEKSNodeRole
readonly cni_node_role=kontainAmazonEKSCNINodeRole
readonly launch_template_name=kontain-eks-launch-template
readonly node_group_name=kontain-eks-node-grooup
readonly fingerprint=0FD7A5400B4769A5DB5A5FCF4BC970FDF2FD236F

do_cleanup() {
    echo "cleanup"
    
    echo "delete nodegroup"
    aws --no-paginate --region=$region eks delete-nodegroup --cluster-name $cluster_name --nodegroup-name $node_group_name --output text > /dev/null
    aws --no-paginate --region=$region eks wait nodegroup-deleted --cluster-name $cluster_name --nodegroup-name $node_group_name

    echo "delete cluster"
    aws --no-paginate --region=$region eks delete-cluster --name $cluster_name --no-paginate --output text > /dev/null
    aws --no-paginate --region=$region eks wait cluster-deleted --name $cluster_name --no-paginate

    echo "delete cloudformation stack"
    aws --no-paginate --region=$region cloudformation delete-stack  --stack-name $stack_name --output text > /dev/null
    aws --no-paginate --no-cli-pager --region $region cloudformation wait stack-delete-complete --stack-name $stack_name

    echo "delete launch templete"
    aws --region=$region ec2 delete-launch-template --launch-template-name $launch_template_name --output text > /dev/null

    echo "delete node role"
    aws --region=$region iam detach-role-policy \
        --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy \
        --role-name $node_role --output text > /dev/null
    aws --region=$region iam detach-role-policy \
        --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly \
        --role-name $node_role --output text > /dev/null
    aws --region=$region iam detach-role-policy \
        --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy \
        --role-name $node_role --output text > /dev/null
    aws --region=$region iam detach-role-policy \
        --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
        --role-name $node_role --output text > /dev/null
    aws --region=$region iam delete-role --role-name $node_role

    echo "delete CNI role"
    aws --region=$region iam detach-role-policy \
        --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy \
        --role-name $cni_node_role --output text > /dev/null
    aws --region=$region iam delete-role --role-name $cni_node_role --output text > /dev/null

    echo "delete cluster role"
    aws --region=$region iam detach-role-policy \
        --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy \
        --role-name $cluster_role --output text > /dev/null
    aws --region=$region iam delete-role --role-name $cluster_role --output text > /dev/null

    echo "delete key pair"
    aws --region=$region ec2 delete-key-pair --key-name $key_pair_name --output text > /dev/null
    rm -f $key_pair_name.pem

    echo "remove temporary files"
    rm -f cluster-role-trust-policy.json 
    rm -f user_data.txt
    rm -f launch-config.json
    rm -f vpc-cni-trust-policy.json
    rm -f node-trust-policy.json
}

main() {

cat << EOF > cluster-role-trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF


echo "create key pair"
aws --region=$region ec2 create-key-pair --key-name $key_pair_name --query 'KeyMaterial' --output text > $key_pair_name.pem
chmod 400 $key_pair_name.pem

echo "create Cloudformation VPC Stack"
STACK_ID=$(aws cloudformation create-stack \
  --region $region \
  --stack-name $stack_name \
  --template-body file://scripts/amazon-eks-vpc-stack.yaml \
   | jq -r '.StackId')
echo STACK_ID = ${STACK_ID}

echo "waiting for stack to be created"
aws --no-paginate --region $region cloudformation wait stack-create-complete --stack-name $stack_name

VPC_DESC=$(aws --region=$region cloudformation describe-stacks --stack-name $stack_name --query "Stacks[0].Outputs")
echo VPC_DESC = ${VPC_DESC}

SECURITY_GROUP_IDS=$(echo ${VPC_DESC} | jq -r '.[] | select(.OutputKey | contains("SecurityGroups")) | .OutputValue')
SUBNET_IDS=$(echo ${VPC_DESC} | jq -r '.[] | select(.OutputKey | contains("SubnetIds")) | .OutputValue' | tr ',' ' ')
VPC_CONFIG=$(echo ${VPC_DESC} \
    | jq -r '[ .[] | select(.OutputKey | contains("SecurityGroups")), select(.OutputKey | contains("SubnetIds")) | .OutputValue ]' \
    | jq -rj '"securityGroupIds=", .[0], ",subnetIds=", .[1]')
echo VPC_CONFIG = ${VPC_CONFIG}

echo "add ingress rules"
aws --region=$region ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_IDS} \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0

aws --region=$region ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_IDS} \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0

aws --region=$region ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_IDS} \
    --protocol tcp \
    --port 443 \
    --cidr 0.0.0.0/0

aws --region=$region ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_IDS} \
    --protocol tcp \
    --port 10250 \
    --cidr 0.0.0.0/0

aws --region=$region ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_IDS} \
    --protocol tcp \
    --port 53 \
    --cidr 0.0.0.0/0

aws --region=$region ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_IDS} \
    --protocol udp \
    --port 53 \
    --cidr 0.0.0.0/0

echo "create cluster role"
CLUSTER_ROLE_ARN=$(aws --region=$region iam create-role \
  --role-name $cluster_role \
  --assume-role-policy-document file://cluster-role-trust-policy.json |jq -r '.Role |.Arn')
echo CLUSTER_ROLE_ARN = ${CLUSTER_ROLE_ARN}

aws --region=$region iam attach-role-policy \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy \
  --role-name $cluster_role --output text > /dev/null

echo "create cluster"
aws --region=$region eks create-cluster --name $cluster_name \
--role-arn ${CLUSTER_ROLE_ARN} \
--resources-vpc-config ${VPC_CONFIG} --output text > /dev/null

echo "wait for cluster to become active"
aws --no-paginate --region=$region eks wait cluster-active --name $cluster_name

echo "create a kubeconfig file for your cluster"
aws --region=$region eks update-kubeconfig --name $cluster_name


echo "     create node policy config file"
cat << EOF > node-trust-policy.json 
{
    "Version": "2012-10-17",
    "Statement": [
        {
        "Effect": "Allow",
        "Principal": {
            "Service": "ec2.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
        }
    ]
}
EOF

echo "     create node role"
NODE_ROLE_ARN=$(aws --region $region iam create-role --role-name $node_role --assume-role-policy-document file://node-trust-policy.json \
    | jq -r '.Role |.Arn')

# echo "     assign policies"
aws --region=$region iam attach-role-policy \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy \
  --role-name $node_role --output text > /dev/null
aws --region=$region iam attach-role-policy \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly \
  --role-name $node_role --output text > /dev/null
aws --region=$region iam attach-role-policy \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy \
  --role-name $node_role --output text > /dev/null
aws --region=$region iam attach-role-policy \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
  --role-name $node_role --output text > /dev/null

# echo "create VCP CNI node trust policy"
# cat << EOF > vpc-cni-trust-policy.json
# {
#     "Version": "2012-10-17",
#     "Statement": [
#         {
#             "Effect": "Allow",
#             "Principal": {
#                 "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
#             },
#             "Action": "sts:AssumeRoleWithWebIdentity",
#             "Condition": {
#                 "StringEquals": {
#                     "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
#                     "${OIDC_PROVIDER}:sub": "system:serviceaccount:kube-system:aws-node"
#                 }
#             }
#         }
#     ]
# }
# EOF


# echo "     create VPC CNI role"
# VPC_CNI_ROLE_ARN=$(aws --region $region iam create-role --role-name $cni_node_role --assume-role-policy-document file://vpc-cni-trust-policy.json \
#     | jq -r '.Role |.Arn')

# aws --region=$region iam attach-role-policy \
#   --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy \
#   --role-name $cni_node_role --output text > /dev/null

# echo "    annotate kubernetis aws-node service with VPC CNI Role"
# kubectl annotate serviceaccount \
#     --overwrite serviceaccount
#     default \
#     eks.amazonaws.com/role-arn=${VPC_CNI_ROLE_ARN}

echo "create launch template"
cat << EOF > user_data.txt
#!/bin/bash
/etc/eks/bootstrap.sh $cluster_name --container-runtime containerd 
EOF

USER_DATA=$(base64 --wrap=0 user_data.txt)

cat << EOF > launch-config.json
{
    "ImageId":        "$ami_id",
    "InstanceType":   "t3.small",
    "KeyName":       "$key_pair_name",
    "UserData": "${USER_DATA}",
    "NetworkInterfaces": [
        {
            "DeviceIndex": 0,
            "Groups": ["${SECURITY_GROUP_IDS}"]
        }
    ]
}
EOF

aws --region=$region ec2  create-launch-template --launch-template-name $launch_template_name \
    --launch-template-data file://launch-config.json

echo "create node group with subnets ${SUBNET_IDS}"
aws --region=$region eks create-nodegroup --cluster-name $cluster_name --nodegroup-name $node_group_name \
    --launch-template name=$launch_template_name,version='$Latest' \
    --subnets ${SUBNET_IDS} \
    --node-role ${NODE_ROLE_ARN} \
    --scaling-config minSize=1,maxSize=1,desiredSize=1
echo "wait for nodegrop to be active"
aws --region=$region eks wait nodegroup-active --cluster-name $cluster_name --nodegroup-name $node_group_name

echo "init containerd"
kubectl apply -f scripts/config.yaml

# echo wait for pod to start
#kubectl -n kube-system wait pod --for=condition=Ready -l name=kontain-node-initializer --timeout=420s

echo "apply Kontain enabled application image"
kubectl apply -f scripts/k8s.yaml

kubectl -n default wait pod --for=condition=Ready -l app=golang-http-hello

echo "setup port forwarding"
kubectl port-forward svc/golang-http-hello 8080:8080 2>/dev/null &

$PAGE=$(curl -vvv http://localhost:8080)

echo PAGE === ${PAGE}
}

if [[ ! -z $cleanup_only ]]; then
    do_cleanup
    exit
fi

[[ -z $ami_id ]] && echo "ami is required" && exit 1

main

#do_cleanup

