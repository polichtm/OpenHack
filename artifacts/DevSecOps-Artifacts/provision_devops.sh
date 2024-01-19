#!/bin/bash

usage() { echo "Usage: provision_devops.sh -n <teamName> -t <teamNumber> -o <adoOrgName> -s '<personalAccessToken>'" 1>&2; exit 1; }

declare adoOrgName="DevSecOpsOH"
declare repositoryName="eShopOnWeb"
declare templateGitHubProject="https://github.com/microsoft/DevSecOps-OpenHack-Lite_eShopOnWeb"
declare teamName="dsooh"

# Initialize parameters specified from command line
while getopts ":n:t:o:s:" arg; do
    case "${arg}" in

        n)
            teamName=$(echo "${OPTARG}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        ;;
        t)
            teamNumber=$(echo "${OPTARG}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        ;;
        o)
            adoOrgName=${OPTARG}
        ;;
        s)
            personalAccessToken=${OPTARG}
        ;;

    esac
done
shift $((OPTIND-1))

declare organization="https://dev.azure.com/${adoOrgName}"
declare feedUrl="https://pkgs.dev.azure.com/${adoOrgName}/_packaging/${adoOrgName}/nuget/v3/index.json"
declare projectName="${teamName}${teamNumber}"
declare acrConfigFile="${teamName}${teamNumber}_acr.json"
declare subscriptionConfigFile="${teamName}${teamNumber}_subscription.json"

echo "=========================================="
echo " VARIABLES"
echo "=========================================="
echo "adoOrgName                = "${adoOrgName}
echo "organization              = "${organization}
echo "projectName               = "${projectName}
echo "repositoryName            = "${repositoryName}
echo "templateGitHubProject     = "${templateGitHubProject}
echo "teamNumber                = "${teamNumber}
echo "=========================================="

# Fetch the data of ACR. This section assume acr,json was created in previous step
conf=$(cat ${acrConfigFile})
acrUsername=$(echo $conf | jq .acrUserName | xargs )
acrPassword=$(echo $conf | jq .acrPassword | xargs )
acrLoginServer=$(echo $conf | jq .acrLoginServer | xargs )

# Read in SP information
sp_conf=$(cat ${subscriptionConfigFile})
serviceEndpointSpAppId=$(echo $sp_conf | jq .appId | xargs )
serviceEndpointSpPassword=$(echo $sp_conf | jq .password | xargs )
serviceEndpointSpTenant=$(echo $sp_conf | jq .tenant | xargs )
serviceEndpointSubscriptionId=$(echo $sp_conf | jq .subscriptionId | xargs )
serviceEndpointSubscriptionName=$(echo $sp_conf | jq .subscriptionName | xargs )
storageConnectionString=$(echo $sp_conf | jq .storageConnectionString | xargs )

# Check and add extension
az extension add --name azure-devops
export AZURE_DEVOPS_EXT_PAT=${personalAccessToken}
AZURE_DEVOPS_EXT_PAT=${personalAccessToken}
az devops configure --defaults organization=$organization

# Create Project
az devops project create --name $projectName --organization $organization -p Agile

# Prepare Git repo
git config --global user.email "openhackuser@microsoft.com"
git config --global user.name "OpenHack"
git clone $templateGitHubProject $repositoryName
cd $repositoryName
git config core.autocrlf false
git config core.eol lf
git config --bool core.bare false
git checkout master
escapedStorageConnectionString=$(echo "$storageConnectionString" | sed 's/\//\\\//g')

if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "Provisioning from MAC OSX"
    sed -i '' "s/REPLACEWITHCS/${escapedStorageConnectionString}/g" src/Infrastructure/Data/StorageAcctDbSeed.cs
    sed -i '' "s/__ADOORG__/${adoOrgName}/g" nuget.config
else
    echo "provisioning on Windows/Linux"
    sed -i "s/REPLACEWITHCS/${escapedStorageConnectionString}/g" src/Infrastructure/Data/StorageAcctDbSeed.cs
    sed -i "s/__ADOORG__/${adoOrgName}/g" nuget.config
fi

git commit -a -m "Updated connection string & ADO org."
git checkout ch1_Fix
git merge master
perl -i -0pe 's/(<<<<<<< HEAD\n)//gm' src/Infrastructure/Data/StorageAcctDbSeed.cs
perl -i -0pe 's/(=======)([\S\s]*?)(>>>>>>> master\n)//mg' src/Infrastructure/Data/StorageAcctDbSeed.cs
git commit -a -m "Resolved merge conflict."
git checkout master
repoUrl=$(az repos create -p ${projectName} --name ${repositoryName} --organization ${organization} --query 'remoteUrl' -o tsv)
repoUrl=$(sed "s/@/:${personalAccessToken}@/g" <<<$repoUrl)
git push --mirror $repoUrl
cd ..
rm -rf $repositoryName

# Create Two Pipelines with configuring variables and service connection
az pipelines create --name 'eShopOnWeb.CI' --description 'Pipeline for building eShopWeb on Windows' --repository $repositoryName --branch master --repository-type tfsgit --yaml-path eShopOnWeb-CI.yml -p $projectName --skip-run --organization $organization
az pipelines create --name 'eShopOnWeb-Docker.CI' --description 'Pipeline for building eShopWeb on Linux' --repository $repositoryName --branch master --repository-type tfsgit --yaml-path eShopOnWeb-Docker-CI.yml -p $projectName --skip-run --organization $organization

# Configure the variables of ACR
az pipelines variable create --name registryUrl --value $acrLoginServer --pipeline-name 'eShopOnWeb-Docker.CI' -p $projectName --organization $organization
az pipelines variable create --name registryPassword --value $acrPassword --pipeline-name 'eShopOnWeb-Docker.CI' -p $projectName --organization $organization
az pipelines variable create --name registryName --value $acrUsername --pipeline-name 'eShopOnWeb-Docker.CI' -p $projectName --organization $organization
az pipelines variable create --name feedUrl --value $feedUrl --pipeline-name 'eShopOnWeb-Docker.CI' -p $projectName --organization $organization

# Configure the servcie endpoint
export AZURE_DEVOPS_EXT_AZURE_RM_SERVICE_PRINCIPAL_KEY=$serviceEndpointSpPassword
az devops service-endpoint azurerm create --azure-rm-service-principal-id $serviceEndpointSpAppId --azure-rm-subscription-id $serviceEndpointSubscriptionId --azure-rm-subscription-name "${serviceEndpointSubscriptionName}" --azure-rm-tenant-id $serviceEndpointSpTenant --name ${projectName}Se --project ${projectName} --organization $organization

# Delete the default repo
REPO_ID=`az repos list --organization $organization --project $projectName --query "[?name=='$projectName']" | jq '.[0].id' | tr -d '"'`

echo "Deleting repo $projectName with ID: $REPO_ID"

az repos delete --id $REPO_ID --organization $organization --project $projectName --yes

# Append to subscription.json
projectId=$(az devops project show -p $projectName --org $organization | jq .id)
projectIdTrimmed=$(echo "${projectId//\"}")

configeFileData=$(cat ${subscriptionConfigFile})
echo $configeFileData | jq --arg ProjName ${projectName} --arg projId ${projectIdTrimmed} '. + {projectName: $ProjName, projectIdTrimmed: $projId}' | jq . > $subscriptionConfigFile

# Run Docker CI
az pipelines run --name 'eShopOnWeb-Docker.CI' --branch master --project $projectName --organization $organization

# Clear PAT
export AZURE_DEVOPS_EXT_PAT=0
AZURE_DEVOPS_EXT_PAT=0
echo 'Done!'
