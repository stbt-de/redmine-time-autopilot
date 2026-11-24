#!/usr/bin/env bash
# Plugin-Tests gegen ein frisches Redmine (Standard 7.0).
# Aufruf: dev/run-tests.sh            REDMINE_VERSION=6.0 dev/run-tests.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${REDMINE_VERSION:-7.0}"
image="redmine-team-planning-test:$version"

docker build --quiet --build-arg "REDMINE_VERSION=$version" -t "$image" -f "$root/dev/Dockerfile.test" "$root/dev" >/dev/null

docker run --rm \
  -v "$root:/usr/src/redmine/plugins/redmine_time_autopilot:ro" \
  -e RAILS_ENV=test \
  "$image" \
  sh -c "bin/rails redmine:plugins:migrate NAME=redmine_time_autopilot >/dev/null && bin/rails redmine:plugins:test NAME=redmine_time_autopilot"
