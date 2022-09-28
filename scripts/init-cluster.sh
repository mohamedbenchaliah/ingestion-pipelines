#!/bin/bash

ROLE=$(/usr/share/google/get_metadata_value attributes/dataproc-role)
if [[ "${ROLE}" == 'Master' ]]; then
    apt install python3-pip
    pip install -r requirements/requirements.txt
    pip install -r requirements/requirements-dev.txt
fi
