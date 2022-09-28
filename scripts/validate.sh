#!/usr/bin/env bash
set -ex

poetry run isort --check .
poetry run black --check .
#poetry run mypy --install-types --non-interactive jobs
poetry run flake8 jobs/* tests/*
poetry run pylint -j 0 jobs
