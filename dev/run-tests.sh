#!/usr/bin/env bash
# Plugin-Tests gegen ein frisches Redmine (Standard 7.0).
# Aufruf: dev/run-tests.sh                 REDMINE_VERSION=6.0 dev/run-tests.sh
#         WITH_MCP=1 dev/run-tests.sh      mit redmine_mcp_plugin (MCP-Werkzeuge)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
version="${REDMINE_VERSION:-7.0}"
# Getesteter Stand von https://github.com/joaoperfig/redmine_mcp_plugin
mcp_ref="${MCP_PLUGIN_REF:-300e927cecf21cb34b2901ff5a3bfbf743d15e69}"
if [[ -n "${WITH_MCP:-}" ]]; then
  image="redmine-time-autopilot-test:$version-mcp"
  build_args=(--build-arg "MCP_PLUGIN_REF=$mcp_ref")
else
  image="redmine-time-autopilot-test:$version"
  build_args=()
fi

docker build --quiet --build-arg "REDMINE_VERSION=$version" ${build_args[@]+"${build_args[@]}"} -t "$image" -f "$root/dev/Dockerfile.test" "$root/dev" >/dev/null

docker run --rm \
  -v "$root:/usr/src/redmine/plugins/redmine_time_autopilot:ro" \
  -e RAILS_ENV=test \
  "$image" \
  sh -c "bin/rails redmine:plugins:migrate NAME=redmine_time_autopilot >/dev/null && bin/rails redmine:plugins:test NAME=redmine_time_autopilot"
