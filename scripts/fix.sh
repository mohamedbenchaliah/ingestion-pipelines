#!/usr/bin/env bash
set -ex

poetry run isort jobs tests
poetry run black jobs tests
