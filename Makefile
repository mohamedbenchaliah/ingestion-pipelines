# =========================================
#       		VARIABLES
# -----------------------------------------

LINT_DIRS := jobs/ tests/
TO_CLEAN  := build pip-wheel-metadata/
TODAY := $(shell date '+%Y-%m-%d')
PYTEST_OPTS := ''
OS = $(shell uname -s)
VERSION=$(shell python setup.py --version | sed 's/\([0-9]*\.[0-9]*\.[0-9]*\).*$$/\1/')
UUID = $(shell date +%s)

PROJECT_ID ?= c4-gdw-dev
ENV ?= dev
WHEEL_VERSION ?= 1.0.0
REGION ?= europe-west1
PROJECT_NUMBER ?= $$(gcloud projects list --filter=${PROJECT_ID} --format="value(PROJECT_NUMBER)")
ARTIFACTS_BUCKET ?= c4-gdw-pss-artifactory-bucket-${PROJECT_NUMBER}
STAGING_BUCKET ?= c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}
RAWDATA_BUCKET ?= c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER}

# =========================================
#       			HELP
# -----------------------------------------

define PRINT_HELP_PYSCRIPT
import re, sys

for line in sys.stdin:
	match = re.match(r'^([a-zA-Z_-]+):.*?## (.*)$$', line)
	if match:
		target, help = match.groups()
		print("%-20s %s" % (target, help))
endef
export PRINT_HELP_PYSCRIPT

help:
	@python -c "$$PRINT_HELP_PYSCRIPT" < $(MAKEFILE_LIST)

# =========================================
#       		TARGETS
# -----------------------------------------

help: help
clean: clean-build clean-pyc clean-test ## remove all build, test, coverage and Python artifacts
install-all: install install-dev ## install all dependencies
lint: lint ## run flake8 on gdw_engine/ for linting
format: format ## run black on gdw_engine/ for code formatting
typing: typing ## run mypy on gdw_engine/ for code typing check
test: test ## run code unittests
coverage: coverage ## run code coverage
package: package ## build a job wheel
freeze: freeze ## compile req.txt files
docs-build: docs-build ## build docs
docs-launch: docs-launch ## launch docs locally
security-baseline: security-baseline ## Check code vulnerabilities
complexity-baseline: complexity-baseline ## Check code complexity
setup-gcp: setup-gcp ## Setup GCP Buckets and Dataset

# =========================================
#       	   SETUP GCP
# -----------------------------------------

.PHONY: setup-gcp
setup-gcp: ## Setup GCP Buckets and Dataset
	@gsutil mb -c standard -l ${REGION} -p ${PROJECT_ID} gs://${ARTIFACTS_BUCKET}
	@gsutil mb -c standard -l ${REGION} -p ${PROJECT_ID} gs://${STAGING_BUCKET}
	@gsutil mb -c standard -l ${REGION} -p ${PROJECT_ID} gs://${RAWDATA_BUCKET}
	@bq mk --location=${REGION} -d --project_id=${PROJECT_ID} --quiet products_referential
	@echo "The Following Buckets created - ${ARTIFACTS_BUCKET}, ${STAGING_BUCKET}, ${RAWDATA_BUCKET} and 1 BQ Dataset (temp_spark_dataset) Created in project ${PROJECT_ID}"

# =========================================
#       	   COMPILE PIP
# -----------------------------------------

.PHONY: freeze
freeze: ## compile pip packages
	@pip3 install --upgrade pip
	@pip3 install pip-tools --upgrade
	@python3 -m piptools compile requirements/requirements.in --output-file=requirements/requirements.txt
	@python3 -m piptools compile requirements/requirements-dev.in --output-file=requirements/requirements-dev.txt

# =========================================
#       	INSTALL DEPENDENCIES
# -----------------------------------------

.PHONY: install
install: ## install main job dependencies
	@pip3 install --upgrade pip
	PIP_CONFIG_FILE=pip.conf pip install -r requirements/requirements.txt

.PHONY: install-dev
install-dev: ## install dev dependencies
	@pip3 install --upgrade pip
	PIP_CONFIG_FILE=pip.conf pip install -r requirements/requirements-dev.txt

# =========================================
#       		RUN TESTS
# -----------------------------------------

.PHONY: lint
lint: ## run flake8 on gdw_engine/ for linting
	@flake8 $(LINT_DIRS) --exclude tests/conftest.py

.PHONY: format
format:  ## run black on gdw_engine/ for code formatting
	@black --target-version py37 $(LINT_DIRS) -l 120

.PHONY: typing
typing:  ## run mypy on gdw_engine/ for code typing check
	mypy --ignore-missing-imports -p functions jobs

.PHONY: test
test:  ## run tests
	pytest -vv tests/

.PHONY: coverage
coverage:  ## run code coverage
	coverage run --source=jobs,functions --branch -m pytest tests --junitxml=coverage/test.xml -v
	coverage report --omit=functions/move_file_to_gcs/_helpers.py --fail-under 30


# =========================================
#       	CHECK VULNERABILITY
# -----------------------------------------

.PHONY: security-baseline
security-baseline: ## Check code vulnerabilities
	poetry run bandit -r --exit-zero -b bandit.baseline.json functions

.PHONY: complexity-baseline
complexity-baseline: ## Check code complexity
	$(info Maintenability index)
	poetry run radon mi functions
	$(info Cyclomatic complexity index)
	poetry run xenon --max-absolute C --max-modules C --max-average C lambdas

# =========================================
#       		BUILD FUNCTIONS
# -----------------------------------------

.PHONY: build-functions
build-functions: ## build a zip for each function at build/lambda/*.zip
	@bash scripts/build_functions.sh
	@echo "[OK] Functions built at build/function/*.zip"

# =========================================
#       	UPLOAD FUNCTIONS
# -----------------------------------------

.PHONY: upload-functions
upload-functions: ## Upload functions to GCS artifacts
	@bash scripts/upload_functions.sh -b ${ARTIFACTS_BUCKET}
	@echo "[OK] Functions upload to GCS bucket"

# =========================================
#       	UPLOAD ARTIFACTS
# -----------------------------------------

.PHONY: upload-artifacts
upload-artifacts: ## Upload artifacts to GCS artifacts
	gsutil cp -r ./sql gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/
	gsutil cp -r ./catalog gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/
	gsutil cp -r ./requirements gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/
	gsutil cp -r ./jars gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/
	gsutil cp -r ./configs gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/
	@bash scripts/upload_functions.sh -b ${ARTIFACTS_BUCKET}

# =========================================
#       	CREATE DATAPROC CLUSTER
# -----------------------------------------

.PHONY: create-cluster
create-cluster: ## Run the dataproc serverless job
	gcloud dataproc clusters create pss-base-photo-cluster-${ENV}-${UUID} \
		--enable-component-gateway \
		--bucket ${STAGING_BUCKET} \
		--region europe-west1 \
		--zone europe-west1-b \
		--master-machine-type n1-standard-8 \
		--master-boot-disk-type pd-ssd \
		--master-boot-disk-size 1000 \
		--num-workers 2 \
		--worker-machine-type n1-standard-4 \
		--worker-boot-disk-type pd-ssd \
		--worker-boot-disk-size 1000 \
		--image-version 2.0-debian10 \
		--scopes 'https://www.googleapis.com/auth/cloud-platform' \
		--labels env=sbx,domain=pss,project=gdw,deployment=manual \
		--project ${PROJECT_ID} \
		--metadata 'PIP_PACKAGES=google-cloud-bigquery google-cloud-storage' \
		--service-account dataproc-sa@${PROJECT_ID}.iam.gserviceaccount.com \
		--properties='core:fs.gs.glob.flatlist.enable=false,dataproc:dataproc.logging.stackdriver.job.driver.enable=true,dataproc:secondary-workers.is-preemptible.override=false' \
		--metadata GCS_CONNECTOR_VERSION=2.2.6 \
		--max-age 1d \
		--max-idle=120m \
		--initialization-actions gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/scripts/pip-install.sh
#		--subnet default-subnet \
#    --initialization-actions gs://goog-dataproc-initialization-actions-${REGION}/python/pip-install.sh

# =========================================
#        CONFIGURE DATAPROC CLUSTER
# -----------------------------------------

.PHONY: configure-cluster
configure-cluster: ## Run the dataproc serverless job
	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/configs \
	   --id configure_cluster_${UUID} \
	   -- configure

# =========================================
#             LIST TASKS
# -----------------------------------------

.PHONY: list-jobs
list-jobs: ## Run the dataproc serverless job
	gcloud dataproc jobs list \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --log-http \
       --filter='status.state = ACTIVE AND placement.clusterName = cluster-process-base-photo-dev' \
	   --format="table(jobUuid,status.state)"
	#   --format="table(jobUuid,status.state,statusHistory[0].stateStartTime)"

# =========================================
#       PROCESS DARWIN TABLES TABLE
# -----------------------------------------

.PHONY: create-darwin-table
create-darwin-table: ## Create BQ Tables
	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-1663927562 \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_ww_prd_brd_sub_type_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_ww_prd_brd_sub_type_darwin,layer=darwin \
	   -- create-table \
	   --file sql/darwin/base_photo/f_ww_prd_brd_sub_type_darwin/ddl_f_ww_prd_brd_sub_type_darwin.sql \
	   --target-project c4-gdw-${ENV}

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_ww_prd_brand_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_ww_prd_brand_darwin,layer=darwin \
	   -- create-table \
	   --file sql/darwin/base_photo/f_ww_prd_brand_darwin/ddl_f_ww_prd_brand_darwin.sql \
	   --target-project c4-gdw-${ENV}

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_ww_holding_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_ww_holding_darwin,layer=darwin \
	   -- create-table \
	   --file sql/darwin/base_photo/f_ww_holding_darwin/ddl_f_ww_holding_darwin.sql \
	   --target-project c4-gdw-${ENV}

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_ww_prd_barcode_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_ww_prd_barcode_darwin,layer=darwin \
	   -- create-table \
	   --file sql/darwin/base_photo/f_ww_prd_barcode_darwin/ddl_f_ww_prd_barcode_darwin.sql \
	   --target-project c4-gdw-${ENV}

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_ww_buyers_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_ww_buyers_darwin,layer=darwin \
	   -- create-table \
	   --file sql/darwin/base_photo/f_ww_buyers_darwin/ddl_f_ww_buyers_darwin.sql \
	   --target-project c4-gdw-${ENV}

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_ww_prd_str_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_ww_prd_str_darwin,layer=darwin \
	   -- create-table \
	   --file sql/darwin/base_photo/f_ww_prd_str_darwin/ddl_f_ww_prd_str_darwin.sql \
	   --target-project c4-gdw-${ENV}

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_ww_half_season_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_ww_half_season_darwin,layer=darwin \
	   -- create-table \
	   --file sql/darwin/base_photo/f_ww_half_season_darwin/ddl_f_ww_half_season_darwin.sql \
	   --target-project c4-gdw-${ENV}

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_ww_season_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_ww_season_darwin,layer=darwin \
	   -- create-table \
	   --file sql/darwin/base_photo/f_ww_season_darwin/ddl_f_ww_season_darwin.sql \
	   --target-project c4-gdw-${ENV}

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_ww_prd_brd_chart_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_ww_prd_brd_chart_darwin,layer=darwin \
	   -- create-table \
	   --file sql/darwin/base_photo/f_ww_prd_brd_chart_darwin/ddl_f_ww_prd_brd_chart_darwin.sql \
	   --target-project c4-gdw-${ENV}

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_pur_coll_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_pur_coll_darwin,layer=darwin \
	   -- create-table \
	   --file sql/darwin/base_photo/f_pur_coll_darwin/ddl_f_pur_coll_darwin.sql \
	   --target-project c4-gdw-${ENV}


.PHONY: load-darwin-tables
load-darwin-tables: ## Load data into BQ Tables
	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_ww_prd_str_darwin,layer=darwin \
	   --id load_table_f_ww_prd_str_darwin_${UUID} \
	   --log-http \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_ww_prd_str \
	   --target-table f_ww_prd_str_darwin \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "SRC_KEY STRING not null, WW_SUB_CLASS_KEY STRING not null, WW_SUB_CLASS_DESC_FR STRING not null, WW_SUB_CLASS_DESC_EN STRING, WW_SUB_CLASS_DESC_ES STRING, WW_CLASS_KEY STRING not null, WW_CLASS_DESC_FR STRING not null, WW_CLASS_DESC_EN STRING, WW_CLASS_DESC_ES STRING, WW_GRP_CLASS_KEY STRING not null, WW_GRP_CLASS_DESC_FR STRING not null, WW_GRP_CLASS_DESC_EN STRING, WW_GRP_CLASS_DESC_ES STRING, WW_DEPARTMENT_KEY STRING not null, WW_DEPARTMENT_DESC_FR STRING not null, WW_DEPARTMENT_DESC_EN STRING, WW_DEPARTMENT_DESC_ES STRING, WW_SECTOR_KEY STRING not null, WW_SECTOR_DESC_FR STRING not null, WW_SECTOR_DESC_EN STRING, WW_SECTOR_DESC_ES STRING, WW_BUS_KEY STRING not null, WW_BUS_DESC_FR STRING not null, WW_BUS_DESC_EN STRING, WW_BUS_DESC_ES STRING"

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_ww_prd_barcode_darwin,layer=darwin \
	   --id load_table_f_ww_prd_barcode_darwin_${UUID} \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_ww_prd_barcode \
	   --target-table f_ww_prd_barcode_darwin \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "SRC_KEY STRING not null, BARCODE STRING not null, WW_ITEM_DESC STRING, WW_SUB_CLASS_KEY STRING not null, WW_BRAND_SUB_TYPE_KEY STRING not null, WW_SUP_HOLDING_KEY STRING not null, WW_BRAND_KEY STRING not null, WW_CHART_KEY STRING not null, WW_COM_NAME_DESC STRING, WW_ITEM_KEY STRING not null, PRD_VAR_WEIGHT_FLAG STRING not null, PRD_CAPA_VOLUME INTEGER, PRD_CAPA_TYPE STRING not null, WW_DISPO_KEY STRING not null, CREATE_DATE DATE, PUR_STOP_FLAG STRING not null, LEAD_TIME INTEGER, UNIT_NBR_CASE INTEGER, UNIT_FACING INTEGER, UNIT_HEIGHT INTEGER, UNIT_DEPTH INTEGER, DEGREE_ALC INTEGER, NB_LANG INTEGER, SPECIF_DESC STRING, FLAVOUR_DESC STRING, PRD_REF_TYPE STRING, WW_SIZE_KEY STRING, WW_SIZE_DESC STRING, WW_COLOR_KEY STRING, WW_COLOR_DESC STRING, PRD_SUP_KEY STRING, WW_BUYER_KEY STRING, PRD_ASS_TYPE STRING, WW_PRD_COUNTRY_KEY STRING, WW_PRD_SRC_OFFICE STRING, SUPPLIER_NBR INTEGER, SRC_OFFICE_NBR INTEGER, PAV_FLAG INTEGER, LICENSE_NAME STRING, FRANCHISE_NAME STRING, CHARACTER_NAME STRING, LICENSE_TYPE STRING, WW_MAIN_COLOR_KEY STRING, FLAG_BIO BOOLEAN not null"

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_ww_buyers_darwin,layer=darwin \
	   --id load_table_f_ww_buyers_darwin_${UUID} \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_ww_buyers \
	   --target-table f_ww_buyers_darwin \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "SRC_KEY STRING, WW_BUYER_KEY STRING, WW_BUYER_NAME STRING, BUYER_STOP_FLAG STRING, NEGO_GRP_KEY STRING, NEGO_GRP_DESC STRING, DIRECTION_KEY STRING, DIRECTION_DESC STRING"

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_ww_prd_brd_sub_type_darwin,layer=darwin \
	   --id load_table_f_ww_prd_brd_sub_type_darwin_${UUID} \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_ww_prd_brd_sub_type \
	   --target-table f_ww_prd_brd_sub_type_darwin \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "WW_BRAND_SUB_TYPE_KEY STRING, WW_BRAND_SUB_TYPE_DESC_EN STRING, WW_BRAND_SUB_TYPE_DESC_ES STRING, WW_BRAND_SUB_TYPE_DESC_FR STRING, WW_BRAND_TYPE_KEY STRING, WW_BRAND_TYPE_DESC_EN STRING, WW_BRAND_TYPE_DESC_ES STRING, WW_BRAND_TYPE_DESC_FR STRING"

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_ww_prd_brand_darwin,layer=darwin \
	   --id load_table_f_ww_prd_brand_darwin_${UUID} \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_ww_prd_brand \
	   --target-table f_ww_prd_brand_darwin \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "SRC_KEY STRING, WW_BRAND_KEY STRING, WW_BRAND_DESC STRING"

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_ww_holding_darwin,layer=darwin \
	   --id load_table_f_ww_holding_darwin_${UUID} \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_ww_holding \
	   --target-table f_ww_holding_darwin \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "SRC_KEY STRING, WW_HOLDING_KEY STRING, WW_HOLDING_DESC STRING, ADDRESS1 STRING, ADDRESS2 STRING, POSTCODE STRING, TOWN STRING, HLD_COUNTRY_KEY STRING, HLD_STOP_FLAG STRING, HLD_OP_KEY STRING"

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_ww_half_season_darwin,layer=darwin \
	   --id load_table_f_ww_half_season_darwin_${UUID} \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_ww_half_season \
	   --target-table f_ww_half_season_darwin \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "HALF_SEASON_KEY STRING, HALF_SEASON_DESC STRING"

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_ww_season_darwin,layer=darwin \
	   --id load_table_f_ww_season_darwin_${UUID} \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_ww_season \
	   --target-table f_ww_season_darwin \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "WW_SEASON_KEY STRING, WW_SEASON_DESC_FR STRING, WW_SEASON_DESC_EN STRING, WW_SEASON_DESC_ES STRING"

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_ww_prd_brd_sub_type_darwin,layer=darwin \
	   --id load_table_f_ww_prd_brd_chart_darwin_${UUID} \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_ww_prd_brd_chart \
	   --target-table f_ww_prd_brd_chart_darwin \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "SRC_KEY STRING, WW_CHART_KEY STRING, WW_CHART_DESC STRING"

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_pur_coll_darwin,layer=darwin \
	   --id load_table_f_pur_coll_darwin_${UUID} \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_pur_coll \
	   --target-table f_pur_coll_darwin \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "SRC_KEY STRING, COLLECTION_KEY STRING, BARCODE STRING, COLLECTION_DESC STRING, BEG_DATE_KEY INTEGER, END_DATE_KEY INTEGER, PRODUCT_LINE_KEY STRING, PRODUCT_LINE_DESC STRING, WW_BUYER_KEY STRING"


.PHONY: update-darwin-schema
update-darwin-schema: ## Update BQ table Schema
	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_ww_prd_barcode_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_ww_prd_barcode_darwin,layer=darwin \
	   -- update-schema \
	   --target-table f_ww_prd_barcode_darwin \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_ww_buyers_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_ww_buyers_darwin,layer=darwin \
	   --log-http \
	   -- update-schema \
	   --target-table f_ww_buyers_darwin \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_ww_prd_str_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_ww_prd_str_darwin,layer=darwin \
	   -- update-schema \
	   --target-table f_ww_prd_str_darwin \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_ww_holding_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_ww_holding_darwin,layer=darwin \
	   -- update-schema \
	   --target-table f_ww_holding_darwin \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_ww_prd_brand_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_ww_prd_brand_darwin,layer=darwin \
	   -- update-schema \
	   --target-table f_ww_prd_brand_darwin \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_ww_prd_brd_sub_type_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_ww_prd_brd_sub_type_darwin,layer=darwin \
	   -- update-schema \
	   --target-table f_ww_prd_brd_sub_type_darwin \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_pur_coll_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_pur_coll_darwin,layer=darwin \
	   -- update-schema \
	   --target-table f_pur_coll_darwin \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_ww_half_season_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_ww_half_season_darwin,layer=darwin \
	   -- update-schema \
	   --target-table f_ww_half_season_darwin \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_ww_season_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_ww_season_darwin,layer=darwin \
	   -- update-schema \
	   --target-table f_ww_season_darwin \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_ww_prd_brd_chart_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_ww_prd_brd_chart_darwin,layer=darwin \
	   -- update-schema \
	   --target-table f_ww_prd_brd_chart_darwin \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential


.PHONY: scan-darwin-tables
scan-darwin-tables: ## Run the dataproc serverless job
	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/configs \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id scan_table_f_ww_half_season_darwin_${UUID} \
	   --labels env=${ENV},domain=pss,task=quality_scan,table=f_ww_half_season_darwin \
	   -- quality-scan \
	   --source-project ${PROJECT_ID} \
	   --target-project ${PROJECT_ID} \
	   --target-table data_quality \
	   --source-dataset products_referential \
	   --target-dataset products_referential \
	   --materialization-dataset pss_dataset_checkpoints \
	   --temporary-gcs-bucket gs://${STAGING_BUCKET} \
	   --config-path ./configs/darwin/base_photo/f_ww_half_season_darwin/f_ww_half_season.json


# =========================================
#       PROCESS CORE TABLES TABLE
# -----------------------------------------

.PHONY: create-core-table
create-core-table: ## Create BQ Tables
	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_ww_prd_brd_sub_type_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_ww_prd_brd_sub_type_core,layer=core \
	   -- create-table \
	   --file sql/core/base_photo/f_ww_prd_brd_sub_type_core/ddl_f_ww_prd_brd_sub_type_core.sql \
	   --target-project c4-gdw-${ENV}

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_ww_prd_brand_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_ww_prd_brand_core,layer=core \
	   -- create-table \
	   --file sql/core/base_photo/f_ww_prd_brand_core/ddl_f_ww_prd_brand_core.sql \
	   --target-project c4-gdw-${ENV}

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_ww_holding_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_ww_holding_core,layer=core \
	   -- create-table \
	   --file sql/core/base_photo/f_ww_holding_core/ddl_f_ww_holding_core.sql \
	   --target-project c4-gdw-${ENV}

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_ww_prd_barcode_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_ww_prd_barcode_core,layer=core \
	   -- create-table \
	   --file sql/core/base_photo/f_ww_prd_barcode_core/ddl_f_ww_prd_barcode_core.sql \
	   --target-project c4-gdw-${ENV}

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_ww_buyers_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_ww_buyers_core,layer=core \
	   -- create-table \
	   --file sql/core/base_photo/f_ww_buyers_core/ddl_f_ww_buyers_core.sql \
	   --target-project c4-gdw-${ENV}

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_ww_prd_str_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_ww_prd_str_core,layer=core \
	   -- create-table \
	   --file sql/core/base_photo/f_ww_prd_str_core/ddl_f_ww_prd_str_core.sql \
	   --target-project c4-gdw-${ENV}

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_ww_half_season_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_ww_half_season_core,layer=core \
	   -- create-table \
	   --file sql/core/base_photo/f_ww_half_season_core/ddl_f_ww_half_season_core.sql \
	   --target-project c4-gdw-${ENV}

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_ww_season_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_ww_season_core,layer=core \
	   -- create-table \
	   --file sql/core/base_photo/f_ww_season_core/ddl_f_ww_season_core.sql \
	   --target-project c4-gdw-${ENV}

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_ww_prd_brd_chart_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_ww_prd_brd_chart_core,layer=core \
	   -- create-table \
	   --file sql/core/base_photo/f_ww_prd_brd_chart_core/ddl_f_ww_prd_brd_chart_core.sql \
	   --target-project c4-gdw-${ENV}

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/jars \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id create_table_f_pur_coll_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=create_table,table=f_pur_coll_core,layer=core \
	   -- create-table \
	   --file sql/core/base_photo/f_pur_coll_core/ddl_f_pur_coll_core.sql \
	   --target-project c4-gdw-${ENV}


.PHONY: load-core-tables
load-core-tables: ## Load data into BQ Tables
	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_ww_prd_str_core,layer=core \
	   --id load_table_f_ww_prd_str_core_${UUID} \
	   --log-http \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_ww_prd_str_darwin \
	   --target-table f_ww_prd_str_core \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "SRC_KEY STRING not null, WW_SUB_CLASS_KEY STRING not null, WW_SUB_CLASS_DESC_FR STRING not null, WW_SUB_CLASS_DESC_EN STRING, WW_SUB_CLASS_DESC_ES STRING, WW_CLASS_KEY STRING not null, WW_CLASS_DESC_FR STRING not null, WW_CLASS_DESC_EN STRING, WW_CLASS_DESC_ES STRING, WW_GRP_CLASS_KEY STRING not null, WW_GRP_CLASS_DESC_FR STRING not null, WW_GRP_CLASS_DESC_EN STRING, WW_GRP_CLASS_DESC_ES STRING, WW_DEPARTMENT_KEY STRING not null, WW_DEPARTMENT_DESC_FR STRING not null, WW_DEPARTMENT_DESC_EN STRING, WW_DEPARTMENT_DESC_ES STRING, WW_SECTOR_KEY STRING not null, WW_SECTOR_DESC_FR STRING not null, WW_SECTOR_DESC_EN STRING, WW_SECTOR_DESC_ES STRING, WW_BUS_KEY STRING not null, WW_BUS_DESC_FR STRING not null, WW_BUS_DESC_EN STRING, WW_BUS_DESC_ES STRING"

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_ww_prd_barcode_core,layer=core \
	   --id load_table_f_ww_prd_barcode_core_${UUID} \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_ww_prd_barcode_darwin \
	   --target-table f_ww_prd_barcode_core \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "SRC_KEY STRING not null, BARCODE STRING not null, WW_ITEM_DESC STRING, WW_SUB_CLASS_KEY STRING not null, WW_BRAND_SUB_TYPE_KEY STRING not null, WW_SUP_HOLDING_KEY STRING not null, WW_BRAND_KEY STRING not null, WW_CHART_KEY STRING not null, WW_COM_NAME_DESC STRING, WW_ITEM_KEY STRING not null, PRD_VAR_WEIGHT_FLAG STRING not null, PRD_CAPA_VOLUME INTEGER, PRD_CAPA_TYPE STRING not null, WW_DISPO_KEY STRING not null, CREATE_DATE DATE, PUR_STOP_FLAG STRING not null, LEAD_TIME INTEGER, UNIT_NBR_CASE INTEGER, UNIT_FACING INTEGER, UNIT_HEIGHT INTEGER, UNIT_DEPTH INTEGER, DEGREE_ALC INTEGER, NB_LANG INTEGER, SPECIF_DESC STRING, FLAVOUR_DESC STRING, PRD_REF_TYPE STRING, WW_SIZE_KEY STRING, WW_SIZE_DESC STRING, WW_COLOR_KEY STRING, WW_COLOR_DESC STRING, PRD_SUP_KEY STRING, WW_BUYER_KEY STRING, PRD_ASS_TYPE STRING, WW_PRD_COUNTRY_KEY STRING, WW_PRD_SRC_OFFICE STRING, SUPPLIER_NBR INTEGER, SRC_OFFICE_NBR INTEGER, PAV_FLAG INTEGER, LICENSE_NAME STRING, FRANCHISE_NAME STRING, CHARACTER_NAME STRING, LICENSE_TYPE STRING, WW_MAIN_COLOR_KEY STRING, FLAG_BIO BOOLEAN not null"

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_ww_buyers_core,layer=core \
	   --id load_table_f_ww_buyers_core_${UUID} \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_ww_buyers_darwin \
	   --target-table f_ww_buyers_core \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "SRC_KEY STRING, WW_BUYER_KEY STRING, WW_BUYER_NAME STRING, BUYER_STOP_FLAG STRING, NEGO_GRP_KEY STRING, NEGO_GRP_DESC STRING, DIRECTION_KEY STRING, DIRECTION_DESC STRING"

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_ww_prd_brd_sub_type_core,layer=core \
	   --id load_table_f_ww_prd_brd_sub_type_core_${UUID} \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_ww_prd_brd_sub_type_darwin \
	   --target-table f_ww_prd_brd_sub_type_core \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "WW_BRAND_SUB_TYPE_KEY STRING, WW_BRAND_SUB_TYPE_DESC_EN STRING, WW_BRAND_SUB_TYPE_DESC_ES STRING, WW_BRAND_SUB_TYPE_DESC_FR STRING, WW_BRAND_TYPE_KEY STRING, WW_BRAND_TYPE_DESC_EN STRING, WW_BRAND_TYPE_DESC_ES STRING, WW_BRAND_TYPE_DESC_FR STRING"

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_ww_prd_brand_core,layer=core \
	   --id load_table_f_ww_prd_brand_core_${UUID} \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_ww_prd_brand_darwin \
	   --target-table f_ww_prd_brand_core \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "SRC_KEY STRING, WW_BRAND_KEY STRING, WW_BRAND_DESC STRING"

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_ww_holding_core,layer=core \
	   --id load_table_f_ww_holding_core_${UUID} \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_ww_holding_darwin \
	   --target-table f_ww_holding_core \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "SRC_KEY STRING, WW_HOLDING_KEY STRING, WW_HOLDING_DESC STRING, ADDRESS1 STRING, ADDRESS2 STRING, POSTCODE STRING, TOWN STRING, HLD_COUNTRY_KEY STRING, HLD_STOP_FLAG STRING, HLD_OP_KEY STRING"

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_ww_half_season_core,layer=core \
	   --id load_table_f_ww_half_season_core_${UUID} \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_ww_half_season_darwin \
	   --target-table f_ww_half_season_core \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "HALF_SEASON_KEY STRING, HALF_SEASON_DESC STRING"

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_ww_season_core,layer=core \
	   --id load_table_f_ww_season_core_${UUID} \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_ww_season_darwin \
	   --target-table f_ww_season_core \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "WW_SEASON_KEY STRING, WW_SEASON_DESC_FR STRING, WW_SEASON_DESC_EN STRING, WW_SEASON_DESC_ES STRING"

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_ww_prd_brd_sub_type_core,layer=core \
	   --id load_table_f_ww_prd_brd_chart_core_${UUID} \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_ww_prd_brd_chart_darwin \
	   --target-table f_ww_prd_brd_chart_core \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "SRC_KEY STRING, WW_CHART_KEY STRING, WW_CHART_DESC STRING"

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --labels env=${ENV},domain=pss,task=load_table,table=f_pur_coll_core,layer=core \
	   --id load_table_f_pur_coll_core_${UUID} \
	   -- load-csv \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential \
	   --source-bucket c4-gdw-pss-rawdata-bucket-${PROJECT_NUMBER} \
	   --source-table f_pur_coll_darwin \
	   --target-table f_pur_coll_core \
	   --temporary-gcs-bucket c4-gdw-pss-staging-bucket-${PROJECT_NUMBER}  \
	   --materialization-dataset pss_dataset_checkpoints \
	   --partition-date 2022/09/19 \
	   --target-table-schema "SRC_KEY STRING, COLLECTION_KEY STRING, BARCODE STRING, COLLECTION_DESC STRING, BEG_DATE_KEY INTEGER, END_DATE_KEY INTEGER, PRODUCT_LINE_KEY STRING, PRODUCT_LINE_DESC STRING, WW_BUYER_KEY STRING"


.PHONY: update-core-schema
update-core-schema: ## Update BQ table Schema
	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_ww_prd_barcode_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_ww_prd_barcode_core,layer=core \
	   -- update-schema \
	   --target-table f_ww_prd_barcode_core \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_ww_buyers_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_ww_buyers_core,layer=core \
	   --log-http \
	   -- update-schema \
	   --target-table f_ww_buyers_core \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_ww_prd_str_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_ww_prd_str_core,layer=core \
	   -- update-schema \
	   --target-table f_ww_prd_str_core \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_ww_holding_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_ww_holding_core,layer=core \
	   -- update-schema \
	   --target-table f_ww_holding_core \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_ww_prd_brand_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_ww_prd_brand_core,layer=core \
	   -- update-schema \
	   --target-table f_ww_prd_brand_core \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_ww_prd_brd_sub_type_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_ww_prd_brd_sub_type_core,layer=core \
	   -- update-schema \
	   --target-table f_ww_prd_brd_sub_type_core \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_pur_coll_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_pur_coll_core,layer=core \
	   -- update-schema \
	   --target-table f_pur_coll_core \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_ww_half_season_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_ww_half_season_core,layer=core \
	   -- update-schema \
	   --target-table f_ww_half_season_core \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_ww_season_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_ww_season_core,layer=core \
	   -- update-schema \
	   --target-table f_ww_season_core \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential

	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id update_table_schema_f_ww_prd_brd_chart_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=update_schema,table=f_ww_prd_brd_chart_core,layer=core \
	   -- update-schema \
	   --target-table f_ww_prd_brd_chart_core \
	   --target-project ${PROJECT_ID} \
	   --target-dataset products_referential


.PHONY: scan-core-tables
scan-core-tables: ## Run the dataproc serverless job
	gcloud beta dataproc jobs submit pyspark gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/tasks_runner.py \
	   --cluster=pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --py-files gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/dist/gdw_engine-${WHEEL_VERSION}-py3-none-any.whl,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/requirements,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/sql,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/catalog,gs://${ARTIFACTS_BUCKET}/gdw/pyfiles/configs \
	   --jars=gs://spark-lib/bigquery/spark-bigquery-latest_2.12.jar \
	   --id scan_table_f_ww_half_season_core_${UUID} \
	   --labels env=${ENV},domain=pss,task=quality_scan,table=f_ww_half_season_core,layer=core \
	   -- quality-scan \
	   --source-project ${PROJECT_ID} \
	   --target-project ${PROJECT_ID} \
	   --target-table data_quality \
	   --source-dataset products_referential \
	   --target-dataset products_referential \
	   --materialization-dataset pss_dataset_checkpoints \
	   --temporary-gcs-bucket gs://${STAGING_BUCKET} \
	   --config-path ./configs/core/base_photo/f_ww_half_season_core/f_ww_half_season_core.json


.PHONY: delete-cluster
delete-cluster: ## Run the dataproc serverless job
	gcloud dataproc clusters delete pss-base-photo-cluster-${ENV}-${UUID} \
	   --region=${REGION} \
	   --async

# =========================================
#       		BUILD DOCS
# -----------------------------------------

.PHONY: docs-build
docs-build: ## Build docs
	@cd scripts/ && ./build-docs.sh

# =========================================
#       		LAUNCH DOCS
# -----------------------------------------

.PHONY: docs-launch
docs-launch: ## Launch docs
	sphinx-autobuild docs docs/build/html

# =========================================
#       			CLEAR
# -----------------------------------------

.PHONY: clean-build
clean-build: ## remove build artifacts
	rm -fr build/
	rm -fr .eggs/
	rm -fr dist/*.py
	find . -name '*.egg-info' -exec rm -fr {} +
	find . -name '*.egg' -exec rm -fr {} +

.PHONY: clean-pyc
clean-pyc: ## remove Python file artifacts
	find . -name '*.pyc' -exec rm -f {} +
	find . -name '*.pyo' -exec rm -f {} +
	find . -name '*~' -exec rm -f {} +
	find . -name '__pycache__' -exec rm -fr {} +
	find . -type d -name venv -prune -o -type d -name __pycache__ -print0 | xargs -0 rm -rf

.PHONY: clean-test
clean-test: ## remove test and coverage artifacts
	rm -f .coverage
	rm -fr coverage/
	rm -fr htmlcov/
	rm -fr .pytest_cache
	rm -fr .mypy_cache/