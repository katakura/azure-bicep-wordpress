#!/bin/sh

set -e
set -x

LOCATION=japaneast
RESOURCE_GROUP=rg-azure-wordpress
ADMIN_PASS='P@ssword'

DEPLOY_NAME=$(date +'deploy-%d%H%M%S')

az group create \
    --location ${LOCATION} \
    --resource-group ${RESOURCE_GROUP}

az deployment group create \
    --name ${DEPLOY_NAME} \
    --resource-group ${RESOURCE_GROUP} \
    --template-file ./deploy.bicep \
    --parameters adminPass=${ADMIN_PASS}

exit 0
