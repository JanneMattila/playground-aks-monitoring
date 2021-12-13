#!/bin/bash

# All the variables for the deployment
subscriptionName="AzureDev"
aadAdminGroupContains="janne''s"

aksName="myaksmonitoring"
workspaceName="mymonitoringworkspace"
vnetName="myaksmonitoring-vnet"
subnetAks="AksSubnet"
identityName="myaksstorage"
resourceGroupName="rg-myaksmonitoring"
location="westeurope"

# Login and set correct context
az login -o table
az account set --subscription $subscriptionName -o table

subscriptionID=$(az account show -o tsv --query id)
az group create -l $location -n $resourceGroupName -o table

# Prepare extensions and providers
az extension add --upgrade --yes --name aks-preview
az extension add --upgrade --yes log-analytics

# Enable feature
az feature register --namespace "Microsoft.ContainerService" --name "PodSubnetPreview"
az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/PodSubnetPreview')].{Name:name,State:properties.state}"
az provider register --namespace Microsoft.ContainerService

# Remove extension in case conflicting previews
az extension remove --name aks-preview

aadAdmingGroup=$(az ad group list --display-name $aadAdminGroupContains --query [].objectId -o tsv)
echo $aadAdmingGroup

workspaceid=$(az monitor log-analytics workspace create -g $resourceGroupName -n $workspaceName --query id -o tsv)
echo $workspaceid

vnetid=$(az network vnet create -g $resourceGroupName --name $vnetName \
  --address-prefix 10.0.0.0/8 \
  --query newVNet.id -o tsv)
echo $vnetid

subnetaksid=$(az network vnet subnet create -g $resourceGroupName --vnet-name $vnetName \
  --name $subnetAks --address-prefixes 10.2.0.0/24 \
  --query id -o tsv)
echo $subnetaksid

identityid=$(az identity create --name $identityName --resource-group $resourceGroupName --query id -o tsv)
echo $identityid

az aks get-versions -l $location -o table

# Note: for public cluster you need to authorize your ip to use api
myip=$(curl --no-progress-meter https://api.ipify.org)
echo $myip

# Note about private clusters:
# https://docs.microsoft.com/en-us/azure/aks/private-clusters

# For private cluster add these:
#  --enable-private-cluster
#  --private-dns-zone None

az aks create -g $resourceGroupName -n $aksName \
 --max-pods 50 --network-plugin azure \
 --node-count 3 --enable-cluster-autoscaler --min-count 2 --max-count 3 \
 --node-osdisk-type Ephemeral \
 --node-vm-size Standard_D8ds_v4 \
 --kubernetes-version 1.21.2 \
 --enable-addons monitoring,azure-policy,azure-keyvault-secrets-provider \
 --enable-aad \
 --enable-managed-identity \
 --disable-local-accounts \
 --aad-admin-group-object-ids $aadAdmingGroup \
 --workspace-resource-id $workspaceid \
 --load-balancer-sku standard \
 --vnet-subnet-id $subnetaksid \
 --assign-identity $identityid \
 --api-server-authorized-ip-ranges $myip \
 -o table 

###################################################################
# Enable current ip
az aks update -g $resourceGroupName -n $aksName --api-server-authorized-ip-ranges $myip

# Clear all authorized ip ranges
az aks update -g $resourceGroupName -n $aksName --api-server-authorized-ip-ranges ""
###################################################################

sudo az aks install-cli

az aks get-credentials -n $aksName -g $resourceGroupName --overwrite-existing

kubectl get nodes

# Apply log and prometheus data collection settings 
kubectl apply -f container-azm-ms-agentconfig.yaml

# Create namespace
kubectl apply -f namespace.yaml

# Create deployment & service
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

kubectl get deployment -n demos
kubectl describe deployment -n demos

kubectl get pod -n demos
pod1=$(kubectl get pod -n demos -o name | head -n 1)
echo $pod1

kubectl describe $pod1 -n demos

kubectl get service -n demos

ingressip=$(kubectl get service -n demos -o jsonpath="{.items[0].status.loadBalancer.ingress[0].ip}")
echo $ingressip

curl $ingressip
curl $ingressip/home/privacy
curl $ingressip/notfound
curl $ingressip/metrics

# Query prometheus logs from our test app
workspaceCustomerId=$(az monitor log-analytics workspace create --resource-group $resourceGroupName --workspace-name $workspaceName --query customerId -o tsv)
echo $workspaceCustomerId

az monitor log-analytics query \
  --workspace $workspaceCustomerId \
  --analytics-query "InsightsMetrics | where Namespace == 'prometheus' | summarize by Name" \
  --out table

az monitor log-analytics query \
  --workspace $workspaceCustomerId \
  --analytics-query "InsightsMetrics | where Namespace == 'prometheus' and parse_json(Tags).app == 'webapp-monitoring-demo' and Name == 'http_request_duration_seconds_bucket'" \
  --out table

# Wipe out the resources
az group delete --name $resourceGroupName -y
