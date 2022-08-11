#!/bin/bash

deployment_name=kontain-test-app

echo "init Runtime"
kubectl apply -f scripts/config.yaml

echo "apply Kontain enabled application image"
kubectl apply -f scripts/k8s.yaml

echo "wait for application to be ready"
kubectl -n default wait pod --for=condition=Ready -l app=$deployment_name --timeout=420s

echo "expose external IP via LoadBalancer"
# This worked - No port forwarding
kubectl expose deployment $deployment_name --type=LoadBalancer --name=$deployment_name

echo "wait for external IP to be assigned"
external_ip=
while [ -z "$external_ip" ]
do 
    external_ip=$(kubectl get svc -o jsonpath="{.items[?(@.spec.type == 'LoadBalancer')].status.loadBalancer.ingress[0].hostname}")
    if [ -z "$external_ip" ]; then
        echo -n "." && sleep 10 
    fi
done
echo "End point ready - ${external_ip}"

PAGE=$(curl --retry-delay 10 --retry 50 --data x= http://${external_ip}:8080 | grep "kontain.KKM")

ERROR_CODE=0
if [ -z "${PAGE}" ]; then
    echo Error: DWEB did not return expected page
    ERROR_CODE=1
else
    echo ${PAGE}
fi

exit ${ERROR_CODE}
