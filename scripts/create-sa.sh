#!/bin/bash
set -euo pipefail


DATE=$(date +%Y%m%d-%H%M%S)
GCLOUD_PROJECT=c4-gdw-ppd
GCLOUD_SA_DATAPROC=dataproc-sa
GCLOUD_SA_CLOUDFUNCTION=raw-cloudfunction-sa
GCLOUD_SA_DATAPROC_EMAIL="${GCLOUD_SA_DATAPROC}@${GCLOUD_PROJECT}.iam.gserviceaccount.com"
GCLOUD_SA_CLOUDFUNCTION_EMAIL="${GCLOUD_SA_CLOUDFUNCTION}@${GCLOUD_PROJECT}.iam.gserviceaccount.com"


GCLOUD="gcloud --project ${GCLOUD_PROJECT}"
echo -e "\nchecking ${GCLOUD}:"
GCLOUD_USER=$(${GCLOUD} config get-value core/account)
echo "connected to ${GCLOUD} with [${GCLOUD_USER}]"


# Dataproc Service Account
echo -e "\nchecking existing service account [${GCLOUD_SA_DATAPROC}]"
#if ! ${GCLOUD} iam service-accounts list --quiet --filter name:"${GCLOUD_SA_DATAPROC}" | grep "${GCLOUD_SA_DATAPROC}"; then
    echo "creating service account [${GCLOUD_SA_DATAPROC}]"
    ${GCLOUD} iam service-accounts create "${GCLOUD_SA_DATAPROC}" \
        --description="Deployed at: ${DATE}; Dataproc Service Account" \
        --display-name="${GCLOUD_SA_DATAPROC}"
#fi

echo -e "\nenable service account [${GCLOUD_SA_DATAPROC}]"
${GCLOUD} iam service-accounts enable "${GCLOUD_SA_DATAPROC_EMAIL}"

echo -e "\nset service account roles [${GCLOUD_SA_DATAPROC}]"

for required_role in \
    roles/storage.admin \
    roles/bigquery.dataOwner \
    roles/logging.logWriter \
    roles/monitoring.admin \
    roles/datastore.owner \
    roles/compute.admin \
    roles/artifactregistry.reader \
    roles/artifactregistry.writer \
    roles/iam.serviceAccountUser \
    roles/iam.serviceAccountTokenCreator \
    roles/bigquery.jobUser \
    roles/dataproc.admin \
    roles/dataproc.worker \
; do
    ${GCLOUD} projects add-iam-policy-binding "${GCLOUD_PROJECT}" \
        --member="serviceAccount:${GCLOUD_SA_DATAPROC_EMAIL}" --role=${required_role}
done
