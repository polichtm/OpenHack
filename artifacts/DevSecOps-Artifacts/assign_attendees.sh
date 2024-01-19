#!/bin/bash

usage() { echo "Usage: assign_attendees.sh -u <userEmails> -n <teamName> -t <teamNumber> -o <adoOrgName> -s '<personalAccessToken>'" 1>&2; exit 1; }

declare adoOrgName="DevSecOpsOH"
declare openHackGroupName='OpenHack'
declare teamName='dsooh'

# Initialize parameters specified from command line
while getopts ":u:n:t:o:s:" arg; do
    case "${arg}" in

        u)
            userEmails=${OPTARG}
        ;;
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
declare projectName="${teamName}${teamNumber}"

echo '=========================================='
echo ' VARIABLES'
echo '=========================================='
echo "adoOrgName                = "${adoOrgName}
echo 'organization              = '${organization}
echo 'openHackGroupName         = '${openHackGroupName}
echo 'projectName               = '${projectName}
echo 'userEmails                = '${userEmails}
echo 'teamNumber                = '${teamNumber}
echo '=========================================='

# Check and add extension
az extension add --name azure-devops
export AZURE_DEVOPS_EXT_PAT=${personalAccessToken}
AZURE_DEVOPS_EXT_PAT=${personalAccessToken}
az devops configure --defaults organization=$organization

# Add users to groups and projects
CurrentIFS=$IFS
IFS=','
read -r -a emails <<< $userEmails
echo 'userEmails: '${userEmails}

for email in ${emails[@]}
do
    echo 'email: '${email}
    memberDescriptor=`az devops user add --email-id $email --license-type stakeholder --organization $organization --send-email-invite false --query 'user.descriptor' --output tsv`
    #openHackGroupDescriptor=`az devops security group list --organization $organization --scope organization --query "graphGroups[?displayName=='${openHackGroupName}'].descriptor" --output tsv`
    projectAdministratorDescriptor=`az devops security group list --organization $organization -p $projectName --scope=project --query "graphGroups[?displayName=='Project Administrators'].descriptor" --output tsv`
    buildAdministratorDescriptor=`az devops security group list --organization $organization -p $projectName --scope=project --query "graphGroups[?displayName=='Build Administrators'].descriptor" --output tsv`
    teamDescriptor=`az devops security group list --organization $organization -p $projectName --scope=project --query "graphGroups[?displayName=='${projectName} Team'].descriptor" --output tsv`
    #az devops security group membership add --group-id $openHackGroupDescriptor --member-id $memberDescriptor --organization $organization
    az devops security group membership add --group-id $projectAdministratorDescriptor --member-id $memberDescriptor --organization $organization
    az devops security group membership add --group-id $buildAdministratorDescriptor --member-id $memberDescriptor --organization $organization
    az devops security group membership add --group-id $teamDescriptor --member-id $memberDescriptor --organization $organization
done

IFS=$CurrentIFS

# Clear PAT
export AZURE_DEVOPS_EXT_PAT=0
AZURE_DEVOPS_EXT_PAT=0

echo 'Done!'
