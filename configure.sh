#!/bin/bash

# This script prepares all the configuration files and install components such as argocd

HELM_ARGOCD=argocd
HELM_PLATFORM=platform-name
PLATFORM_NS=platform
LETSENCRYPT_EMAIL=admin@dx-book.com

GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Parse arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
    --github-token=*)
        export TOKEN="${key#*=}" # Extracts value after '='
        shift                    # Removes processed argument
        ;;
    --upgrade)
        UPGRADE=true
        shift # Removes processed argument
        ;;
    *) # Unknown option
        echo "Unknown argument: $key"
        exit 1
        ;;
    esac
done

# make sure the environment variables defined before are availble for this script
source ~/.profile

# Function to check if all applications are healthy
all_apps_healthy() {
    # Fetch all applications and their statuses
    statuses=$(kubectl get applications.argoproj.io -n argocd -o jsonpath='{.items[*].status.health.status}')

    # Check each status
    for status in $statuses; do
        if [[ $status != "Healthy" ]]; then
            return 1
        fi
    done
    return 0
}

# validations
if [ -z "$GITHUB_TOKEN" ]; then
    echo "You should run this command inside a GitHub Codespace"
fi

if [ -z "$AWS_ACCOUNT" ] || [ -z "$CLUSTER_NAME" ]; then
    echo "Missing environment variables such as AWS_ACCOUNT or CLUSTER_NAME"
fi

if [[ -z "$TOKEN" ]]; then
    echo "GitHub Token not provided"
    exit 1
fi

# replace the already known values.yaml file using the environment variables
yq eval -i '.org = env(GITHUB_ORG) | .domain = env(CLUSTER_NAME) | .root = env(CLUSTER_DOMAIN)' chart/values.yaml
yq eval -i '.aws.account = env(AWS_ACCOUNT) | .aws.region = env(AWS_DEFAULT_REGION)' chart/values.yaml
yq eval -i '.aws.secret.AWS_ACCESS_KEY_ID = env(AWS_ACCESS_KEY_ID) | .aws.secret.AWS_SECRET_ACCESS_KEY = env(AWS_SECRET_ACCESS_KEY)' chart/values.yaml
cp -f chart/values.yaml chart/templates/gene/values.yaml
cp -f chart/values.yaml chart/templates/each/dependencies/values.yaml

# some of the variables we do not know yet, such as the github admin secret and the service repositories secret
# so let's replace it here
# trying to use the logged in token from the codespace
yq eval -i '.github.secrets.repositories = env(TOKEN)' chart/values.yaml

# install argocd
if helm list --all-namespaces | grep -q "^$HELM_ARGOCD\s"; then
    echo -n ""
else
    helm repo add argo https://argoproj.github.io/argo-helm &>/dev/null
    helm repo update &>/dev/null
    kubectl create namespace argocd &>/dev/null
    helm install argocd argo/argo-cd --namespace argocd --set configs.params."server\.insecure"=true &>/dev/null
fi

sleep 5

# attempt to login to argocd
if argocd version --client=false --port-forward --port-forward-namespace argocd &>/dev/null; then
    echo -e "${GREEN}You are logged into ArgoCD.${NC}"
else
    argocd login localhost:8080 --username admin \
        --port-forward --port-forward-namespace argocd --plaintext \
        --password $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
fi

# verify if the chart is installed already, if not, then install
STATUS=$(helm status "$HELM_PLATFORM" 2>&1)
if [[ "$STATUS" == "Error: release: not found" ]]; then
    helm upgrade $HELM_PLATFORM chart --create-namespace --install
    sleep 5
fi

if [[ $UPGRADE == true ]]; then
    helm upgrade $HELM_PLATFORM chart --create-namespace --install
fi

# wait for traefik load balancer to be available
# then update the Route53 DNS with traefik load balancer endpoint
END_TIME=$(($(date +%s) + 120))
while true; do
    STATUS=$(helm status "$HELM_PLATFORM" --output=json | jq -r .info.status)
    if [[ "$STATUS" == "deployed" ]]; then
        echo "Helm release $HELM_PLATFORM has been successfully deployed!"

        echo "Waiting until the traefik load balancer is available..."
        while true; do
            # Get desired and available replicas
            AVAILABLE_REPLICAS=$(kubectl get deployment "traefik" -n "$PLATFORM_NS" -o=jsonpath='{.status.availableReplicas}')
            if [[ "1" == "$AVAILABLE_REPLICAS" ]]; then

                echo -e "${GREEN}Traefik is healthy!${NC}"

                LB_HOSTNAME=$(kubectl get svc traefik -n platform -o jsonpath='{.status.loadBalancer.ingress[*].hostname}')
                HOSTED_ZONE_ID=$(aws route53 list-hosted-zones | jq --arg domain "$CLUSTER_DOMAIN." '.HostedZones[] | select(.Name==$domain) | .Id | split("/")[2]' | tr -d '"')

                echo "Updating the Route53 DNS records to point to $LB_HOSTNAME (Traefik Load Balancer)"
                # Check if the record already exists
                RECORD_EXISTS_1=$(aws route53 list-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID | jq -r ".ResourceRecordSets[] | select(.Name == \"$CLUSTER_NAME.\")")

                # verify if the route 53 dns upadte is needed
                if [ "$LB_HOSTNAME" != "$(echo $RECORD_EXISTS_1 | jq -c ".ResourceRecords[0].Value" | tr -d '"')" ]; then
                    echo "Updating DNS records in Route53"

                    if [[ ! -z $RECORD_EXISTS_1 ]]; then
                        # Delete the record
                        echo -e "Route53 DNS record already exists, deleting first..."
                        aws route53 change-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID --change-batch '{
                          "Comment": "Delete record",
                          "Changes": [{
                          "Action": "DELETE",
                          "ResourceRecordSet": {
                              "Name": "'$CLUSTER_NAME'",
                              "Type": "CNAME",
                              "TTL": 1,
                              "ResourceRecords": '$(echo $RECORD_EXISTS_1 | jq -c ".ResourceRecords")'
                          }
                          }]
                      }' >/dev/null 2>&1

                        echo -e "Also deleting the *.domain"

                        # Delete the record for the *.domain
                        aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch '{
                          "Comment": "Delete record",
                          "Changes": [{
                          "Action": "DELETE",
                          "ResourceRecordSet": {
                              "Name": "'*.$CLUSTER_NAME'",
                              "Type": "CNAME",
                              "TTL": 1,
                              "ResourceRecords": '$(echo $RECORD_EXISTS_1 | jq -c ".ResourceRecords")'
                          }
                          }]
                      }' >/dev/null 2>&1
                    fi

                    # Create the record again
                    aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch "{
                      'Comment': 'Create record',
                      'Changes': [{
                          'Action': 'CREATE',
                          'ResourceRecordSet': {
                          'Name': '$CLUSTER_NAME',
                          'Type': 'CNAME',
                          'TTL': 1,
                          'ResourceRecords': [{
                              'Value': '$LB_HOSTNAME'
                          }]
                          }
                      }]
                  }" >/dev/null 2>&1

                    # Create the record again for the *.domain
                    aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch "{
                      'Comment': 'Create record',
                      'Changes': [{
                          'Action': 'CREATE',
                          'ResourceRecordSet': {
                          'Name': '*.$CLUSTER_NAME',
                          'Type': 'CNAME',
                          'TTL': 1,
                          'ResourceRecords': [{
                              'Value': '$LB_HOSTNAME'
                          }]
                          }
                      }]
                  }" >/dev/null 2>&1
                else
                    echo "Skipping Route53 Hostname update since it's already in sync"
                fi

                echo "apiVersion: cert-manager.io/v1
                kind: ClusterIssuer
                metadata:
                  name: letsencrypt-production
                spec:
                  acme:
                    server: https://acme-v02.api.letsencrypt.org/directory
                    email: $LETSENCRYPT_EMAIL
                    privateKeySecretRef:
                      name: letsencrypt-production
                    solvers:
                    - http01:
                        ingress:
                          class: traefik" | kubectl apply -f -

                echo -e "\n${GREEN}Domain https://argocd.$CLUSTER_NAME should now be available (TTL 60)${NC}"
                echo -e "${GREEN}ArgoCD admin password is: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)${NC}"

                sleep 2

                # Wait loop
                echo -e "\nVerifying ArgoCD applications status.."
                while ! all_apps_healthy; do
                    echo "Waiting for all ArgoCD applications to be healthy..."
                    sleep 10 # Wait for 10 seconds before rechecking
                done
                echo "All ArgoCD applications are healthy!"

                # verify if generators is already deployed or not
                kubectl get applications/generators -n argocd &>/dev/null
                # $? is a special variable that holds the exit status of the last command executed
                if [[ $? -ne 0 ]]; then
                    echo "Activating the generators..."
                    helm upgrade $HELM_PLATFORM chart --set generators=true
                else
                    echo "Generators are active"
                fi

                exit 0

            else
                sleep 2
            fi
        done

    elif [[ "$(date +%s)" -gt "$END_TIME" ]]; then
        echo "Timed out waiting for Helm release $HELM_PLATFORM to be deployed."
        helm upgrade $HELM_PLATFORM chart --create-namespace --install
    else
        sleep 7
    fi
done
