#!/bin/bash
# Deploy AquaVM.

IFS=$'\n\t'

echo "$@"

usage() { echo "Usage provision_aquavm.sh -l <resourceGroupLocation> -n <teamName> -t <teamNumber>" 1>&2; exit 1; }

declare resourceGroupLocation=""
declare teamName="dsooh"
declare teamNumber=""

while getopts ":l:n:t:" arg; do
    case "${arg}" in
        l)
            resourceGroupLocation=${OPTARG}
        ;;
        n)
            teamName=$(echo "${OPTARG}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        ;;
        t)
            teamNumber=$(echo "${OPTARG}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        ;;
    esac
done

shift $((OPTIND-1))

declare diagStorageAccountName="${teamName}${teamNumber}dsa";
declare aquaRgName="${teamName}${teamNumber}aquarg"

echo "=========================================="
echo " VARIABLES"
echo "=========================================="
echo "resourceGroupLocation     = "${resourceGroupLocation}
echo "aquaRgName                = "${aquaRgName}
echo "=========================================="

# Create an Aqua Server for Container Scanning Scenario

echo "Creating Aqua Server"
if [ `az group exists --name ${aquaRgName}` ]; then
    az group delete --name ${aquaRgName} -y
fi

az group create --name ${aquaRgName} --location ${resourceGroupLocation}
az deployment group create --name DeployAqua --resource-group ${aquaRgName} --template-file template.json --parameters @parameters.json --parameters diagStorageAccountName=${diagStorageAccountName}

echo 'Done!'
