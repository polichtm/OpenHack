#!/bin/bash
# Deploy whole infrastructure of DevSecOps openhack.

IFS=$'\n\t'

echo "$@"

usage() { echo "Usage provision_azure_resources.sh -l <resourceGroupLocation> -n <teamName> -t <teamNumber>" 1>&2; exit 1; }

declare resourceGroupLocation=""
declare teamName="dsooh"
declare teamNumber=""

while getopts ":l:n:t:" arg; do
    case "${arg}" in
        l)
            resourceGroupLocation=${OPTARG}
        ;;
        n)
            teamName=${OPTARG}
        ;;
        t)
            teamNumber=$(echo "${OPTARG}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        ;;
    esac
done

shift $((OPTIND-1))



declare resourceGroupName="${teamName}${teamNumber}rg";
declare keyVaultName="${teamName}${teamNumber}kv";
declare registryName="${teamName}${teamNumber}acr";
declare webAppName="${teamName}${teamNumber}web";
declare storageAccountName="${teamName}${teamNumber}sa"
declare devopsProjectName="${teamName}${teamNumber}";
declare acrFileName="${teamName}${teamNumber}_acr.json"
declare subscriptionFileName="${teamName}${teamNumber}_subscription.json"
declare imageName="eshoponweb"
declare tenantId=$(az account show --query tenantId -o tsv)
declare subscriptionId=$(az account show --query id -o tsv)
declare subscriptionName=$(az account show --query name -o tsv)
declare diagStorageAccountName="${teamName}${teamNumber}dsa";
declare aquaRgName="${teamName}${teamNumber}aquarg"

echo "=========================================="
echo " VARIABLES"
echo "=========================================="
echo "subscriptionId            = "${subscriptionId}
echo "subscriptionName          = "${subscriptionName}
echo "tenantId                  = "${tenantId}
echo "resourceGroupLocation     = "${resourceGroupLocation}
echo "resourceGroupName         = "${resourceGroupName}
echo "aquaRgName                = "${aquaRgName}
echo "teamName                  = "${teamName}
echo "teamNumber                = "${teamNumber}
echo "keyVaultName              = "${keyVaultName}
echo "registryName              = "${registryName}
echo "storageAccountName        = "${storageAccountName}
echo "webAppName                = "${webAppName}
echo "=========================================="

# create resourceGroup

az group create -n $resourceGroupName -l $resourceGroupLocation

# Provision KeyVault
az keyvault create -g $resourceGroupName --name $keyVaultName --location $resourceGroupLocation

# Provision ACR
az acr create -g $resourceGroupName --name $registryName --location $resourceGroupLocation --sku Basic --admin-enabled true
az acr update -n $registryName --admin-enabled true

# Fetch the data of ACR
cred=$(az acr credential show -n $registryName)
acrUsername=$(echo $cred | jq .username | xargs )
acrPassword=$(echo $cred | jq .passwords[0].value | xargs )
conf=$(az acr show -n $registryName)
acrLoginServer=$(echo $conf | jq .loginServer | xargs )

acrImageName=${acrLoginServer}/${imageName}

echo "ACR UserName: $acrUsername"
echo "ACR Password: $acrPassword"
echo "ACR Login Server: $acrLoginServer"
echo "Image Name: $acrImageName"

# Provision Storage Account
declare originalStorageAccountFileShareName="eshop"
declare modifiedStorageAccountFileShareName="eshopmodified"

az storage account create --name $storageAccountName --location $resourceGroupLocation --resource-group $resourceGroupName --sku Standard_LRS
ST_CONNECTION_STRING=$(az storage account show-connection-string -n $storageAccountName -g $resourceGroupName --query 'connectionString' -o tsv)

az storage share create --name $originalStorageAccountFileShareName --quota 1 --account-name $storageAccountName
az storage file upload --share-name $originalStorageAccountFileShareName --source ./originalData/CatalogBrands.json --account-name $storageAccountName
az storage file upload --share-name $originalStorageAccountFileShareName --source ./originalData/CatalogItems.json --account-name $storageAccountName
az storage file upload --share-name $originalStorageAccountFileShareName --source ./originalData/CatalogTypes.json --account-name $storageAccountName

az storage share create --name $modifiedStorageAccountFileShareName --quota 1 --account-name $storageAccountName
az storage file upload --share-name $modifiedStorageAccountFileShareName --source ./originalData/CatalogBrands.json --account-name $storageAccountName
az storage file upload --share-name $modifiedStorageAccountFileShareName --source ./modifiedData/CatalogItems.json --account-name $storageAccountName
az storage file upload --share-name $modifiedStorageAccountFileShareName --source ./originalData/CatalogTypes.json --account-name $storageAccountName

echo "StorageConnectionString: ${ST_CONNECTION_STRING}"

# Provision WebApp

# App Service Plan
declare appServicePlanName="${webAppName}plan"
az appservice plan create -n ${appServicePlanName} -g $resourceGroupName --is-linux -l $resourceGroupLocation --sku S1

# WebApp
az webapp create -n $webAppName -g $resourceGroupName -p $appServicePlanName -i $acrImageName
az webapp config container set -n $webAppName -g $resourceGroupName -c $acrImageName -r $acrLoginServer -u $registryName -p "$acrPassword"
az webapp config appsettings set --resource-group $resourceGroupName --name $webAppName --settings WEBSITES_PORT=8080

# Activate Docker Container Logging
az webapp log config -n $webAppName -g $resourceGroupName --web-server-logging filesystem

# Setup Continuous Deployment (https://docs.microsoft.com/en-us/azure/app-service/containers/app-service-linux-cli)
WEB_HOOK_URL=$(az webapp deployment container config -n ${webAppName} -g ${resourceGroupName} -e true | jq .CI_CD_URL | xargs )
az acr webhook create -n WebAppDeployment -r ${registryName} --uri ${WEB_HOOK_URL} --actions push

# output ACR info
jq -n --arg acrU $acrUsername --arg acrP $acrPassword --arg acrLs $acrLoginServer --arg acrIn $acrImageName '{acrUserName: $acrU, acrPassword: $acrP, acrLoginServer: $acrLs, acrImageName: $acrIn}' > $acrFileName

# Create Service Principal and output to .json
export SP_JSON=`az ad sp create-for-rbac --role="Contributor" -o json`
echo $SP_JSON | jq --arg subId ${subscriptionId} --arg subName ${subscriptionName} --arg stConnectionString ${ST_CONNECTION_STRING} '. + {subscriptionId: $subId, subscriptionName: $subName, storageConnectionString: $stConnectionString}' | jq . > $subscriptionFileName
# Add the required kv access-policy for the service principal
declare sp=$(cat $subscriptionFileName | jq .appId | xargs)

sleep 30
az keyvault set-policy -n $keyVaultName --object-id $(az ad sp show --id ${sp} | jq .objectId | xargs ) --secret-permissions get list --key-permissions get list

# Add the required kv access-policy for the web app
declare WEB_APP_SP=$(az webapp identity assign -g $resourceGroupName -n $webAppName | jq .principalId | xargs )

sleep 30
az keyvault set-policy -n $keyVaultName --object-id $WEB_APP_SP --secret-permissions get list --key-permissions get list

# Create an Aqua Server for Container Scanning Scenario

echo "Creating Aqua Server"
if [ `az group exists --name ${aquaRgName}` ]; then
    az group delete --name ${aquaRgName} -y
fi

az group create --name ${aquaRgName} --location ${resourceGroupLocation}
az deployment group create --name DeployAqua --resource-group ${aquaRgName} --template-file template.json --parameters @parameters.json --parameters diagStorageAccountName=${diagStorageAccountName}

echo 'Done!'
