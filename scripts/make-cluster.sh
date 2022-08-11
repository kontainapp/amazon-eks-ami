#!/bin/bash

[ "$TRACE" ] && set -x

region=us-east-2
ami_id=''
cleanup_only=''

arg_count=$#
for arg in "$@"
do
   case "$arg" in
        --region=*)
        region="${1#*=}"
        arg_count=$((arg_count-1))
        ;;
        --ami=*)
        ami_id="${1#*=}"
        ;;
        --cleanup)
            cleanup='yes'
    esac
    shift
done

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

readonly key_pair_name=eks-key
readonly stack_name=kontain-eks-vpc-stack
readonly cluster_role=kontainAmazonEKSClusterRole
readonly cluster_name=kontain-eks-cluster
readonly node_role=kontainAmazonEKSNodeRole
readonly launch_template_name=kontain-eks-launch-template
readonly node_group_name=kontain-eks-node-group
readonly fingerprint=0FD7A5400B4769A5DB5A5FCF4BC970FDF2FD236F

do_cleanup() {
    echo "cleanup"
    
    echo "delete load balancer"
    elb_name=$(kubectl get svc  -o jsonpath="{.items[?(@.spec.type == 'LoadBalancer')].status.loadBalancer.ingress[0].hostname}" | awk -F- '{print $1}')
    echo "found load balancer $elb_name"
    aws --region=$region elb delete-load-balancer --load-balancer-name=$elb_name

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
    rm -f node-trust-policy.json
}

main() {

    echo "create key pair"
    if [ ! -f $key_pair_name.pem ]; then 
        aws --region=$region ec2 create-key-pair --key-name $key_pair_name --query 'KeyMaterial' --output text > $key_pair_name.pem
        chmod 400 $key_pair_name.pem
    else
        echo "  already exists"
    fi

    echo "create Cloudformation VPC Stack"

    VPC_DESC=$(aws --region=$region cloudformation describe-stacks --stack-name $stack_name --query "Stacks[0].Outputs" 2> /dev/null)
    RET=$?
    if [ $RET != 0 ]; then  
        STACK_ID=$(aws cloudformation create-stack \
        --region $region \
        --stack-name $stack_name \
        --template-body file://scripts/amazon-eks-vpc-stack.yaml \
        | jq -r '.StackId')
        echo STACK_ID = ${STACK_ID}

        echo "waiting for stack to be created"
        aws --no-paginate --region $region cloudformation wait stack-create-complete --stack-name $stack_name

        VPC_DESC=$(aws --region=$region cloudformation describe-stacks --stack-name $stack_name --query "Stacks[0].Outputs")
    else
        echo "  already exists"
    fi

    SECURITY_GROUP_IDS=$(echo ${VPC_DESC} | jq -r '.[] | select(.OutputKey | contains("SecurityGroups")) | .OutputValue')
    SUBNET_IDS=$(echo ${VPC_DESC} | jq -r '.[] | select(.OutputKey | contains("SubnetIds")) | .OutputValue' | tr ',' ' ')
    VPC_CONFIG=$(echo ${VPC_DESC} \
        | jq -r '[ .[] | select(.OutputKey | contains("SecurityGroups")), select(.OutputKey | contains("SubnetIds")) | .OutputValue ]' \
        | jq -rj '"securityGroupIds=", .[0], ",subnetIds=", .[1]')

    if [ $RET != 0 ]; then  
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
            --cidr 0.0.0.0/0 > /dev/null

        aws --region=$region ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_IDS} \
            --protocol tcp \
            --port 10250 \
            --cidr 0.0.0.0/0 > /dev/null

        aws --region=$region ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_IDS} \
            --protocol tcp \
            --port 53 \
            --cidr 0.0.0.0/0 > /dev/null

        aws --region=$region ec2 authorize-security-group-ingress --group-id ${SECURITY_GROUP_IDS} \
            --protocol udp \
            --port 53 \
            --cidr 0.0.0.0/0 > /dev/null
    fi

    echo "create cluster role"
    CLUSTER_ROLE_ARN=$(aws --region=$region iam   get-role --role-name $cluster_role  2> /dev/null | jq -r '.Role |.Arn')
    if [ -z ${CLUSTER_ROLE_ARN} ]; then
        echo "  create cluster policy config file"
        json_string='{
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
        }'
        echo "$json_string" > cluster-role-trust-policy.json
        echo "  create role"
        CLUSTER_ROLE_ARN=$(aws --region=$region iam create-role \
        --role-name $cluster_role \
        --assume-role-policy-document file://cluster-role-trust-policy.json |jq -r '.Role |.Arn')

        echo "  attach policies"
        aws --region=$region iam attach-role-policy \
        --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy \
        --role-name $cluster_role --output text > /dev/null
    else
        echo "  already exists"
    fi

    echo "create cluster"
    CLUSTER_ARN=$(aws --region=$region --no-paginate eks describe-cluster --name $cluster_name  2> /dev/null | jq -r '.cluster | .arn')
    if [ -z ${CLUSTER_ARN} ]; then 
        aws --region=$region eks create-cluster --name $cluster_name \
        --role-arn ${CLUSTER_ROLE_ARN} \
        --resources-vpc-config ${VPC_CONFIG} --output text > /dev/null

        echo " waiting for cluster to become active"
        aws --no-paginate --region=$region eks wait cluster-active --name $cluster_name
    else 
        echo " already exists"
    fi

    echo "create a kubeconfig file for cluster"
    aws --region=$region eks update-kubeconfig --name $cluster_name

    echo "create node role"
    NODE_ROLE_ARN=$(aws --region=$region iam get-role --role-name $node_role  2> /dev/null | jq -r '.Role |.Arn')
    if [ -z ${NODE_ROLE_ARN} ]; then
        echo "  create node policy config file"
        json_string='{
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
        }'
        echo "$json_string" >  node-trust-policy.json 

        echo "  create node role"
        NODE_ROLE_ARN=$(aws --region $region iam create-role --role-name $node_role --assume-role-policy-document file://node-trust-policy.json \
            | jq -r '.Role |.Arn')

        echo "  assign policies"
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
    else 
        echo "already exists"
    fi

    echo "create launch template"
    aws --region=$region ec2 describe-launch-templates --launch-template-names kontain-eks-launch-template --output text >& /dev/null
    RET=$?
    if [ $RET != 0 ]; then  
        json_string="#!/bin/bash
/etc/eks/bootstrap.sh $cluster_name"

        echo "  writing user data"
        echo "$json_string" > user_data.txt
        
        USER_DATA=$(base64 --wrap=0 user_data.txt)

        json_string=$(jq  -n \
            "{
                \"ImageId\":        \"$ami_id\",
                \"InstanceType\":   \"t3.small\",
                \"KeyName\":       \"$key_pair_name\",
                \"UserData\": \"$USER_DATA\",
                \"NetworkInterfaces\": [
                    {
                        \"DeviceIndex\": 0,
                        \"Groups\": [\"$SECURITY_GROUP_IDS\"]
                    }
                ]
            }")
        
        echo "  writing launch config"
        echo "$json_string" > launch-config.json

        echo "  creating template"
        aws --region=$region ec2  create-launch-template --launch-template-name $launch_template_name \
            --launch-template-data file://launch-config.json > /dev/null
    else
        echo "already exists"
    fi

    echo "create node group with subnets ${SUBNET_IDS}"
    NODE_GROUP_STATUS=$(aws --region=$region eks describe-nodegroup --cluster-name $cluster_name --nodegroup-name $node_group_name 2> /dev/null | jq -r  '.nodegroup | .status')
    echo "NODE_GROUP_STATUS = $NODE_GROUP_STATUS"
    if [ ! -z $NODE_GROUP_STATUS ] && [ $NODE_GROUP_STATUS == "DELETING" ]; then 
        echo "  node group deleting - wait for completing"
        aws --no-paginate --region=$region eks wait nodegroup-deleted --cluster-name $cluster_name --nodegroup-name $node_group_name
    elif [ -z $NODE_GROUP_STATUS ]; then 
        echo "  creating node group"
        aws --region=$region eks create-nodegroup --cluster-name $cluster_name --nodegroup-name $node_group_name \
            --launch-template name=$launch_template_name,version='$Latest' \
            --subnets ${SUBNET_IDS} \
            --node-role ${NODE_ROLE_ARN} \
            --scaling-config minSize=1,maxSize=1,desiredSize=1 > /dev/null
    else   
        echo "already exists"
    fi
    echo "wait for nodegrop to be active"
    aws --region=$region eks wait nodegroup-active --cluster-name $cluster_name --nodegroup-name $node_group_name
}

if [ ! -z $cleanup ] && [ $arg_count == 1 ]; then
    do_cleanup
    exit
fi

[[ -z $ami_id ]] && echo "ami is required" && exit 1

main

#clean at the end if requested
if [ ! -z $cleanup ]; then 
    do_cleanup
fi
