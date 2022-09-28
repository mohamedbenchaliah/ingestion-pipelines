#!/bin/bash

set -euo pipefail


CRON_EXPRESSION="cron(0 * ? * MON-FRI *)"
REGION="europe-west1"

usage() { echo "Usage: $0 -f <cloud-function-names> [-e <environment>]" 1>&2; exit 1; }

while getopts ":f:e:" arg;
do
    case ${arg} in
        f)
          FUNCTION_NAME=${OPTARG}
          export FUNCTION_NAME
          ;;
        e)
          ENVIRONMENT=${OPTARG}
          export ENVIRONMENT
          ;;
        *) usage ;;
    esac
done


if [[ -z ${ENVIRONMENT+x} ]]
echo "Start Infra deployment ... "
then
    ENVIRONMENT=$ENVIRONMENT
    RAW_FUNCTION_NAME="C4-GDW-$(echo $ENVIRONMENT | tr '[:lower:]' '[:upper:]')-PHOENIX_TO_RAW_FUNCTION"


    echo "---------------  Enabling GCP services  ---------------"
    gcloud services enable \
        cloudfunctions.googleapis.com \
        cloudtrace.googleapis.com \
        pubsub.googleapis.com \
        cloudscheduler.googleapis.com \
        storage-component.googleapis.com \
        bigquery-json.googleapis.com \
        cloudbuild.googleapis.com \
        dataproc.googleapis.com \
        bigquerystorage.googleapis.com



fi
