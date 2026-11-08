#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin"
QUERY_STDIN_LOG="$TMP_DIR/query-stdin.log"
touch "$QUERY_STDIN_LOG"

cat > "$TMP_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args="$*"
printf '%s\n' "$args" >> "${DOCKER_ARGS_LOG:-/dev/null}"
if [[ "$args" == *"--query"* ]]; then
  payload="$(cat)"
  if [[ -n "$payload" ]]; then
    printf '%s\n' "$payload" >> "${QUERY_STDIN_LOG:?}"
  fi

  case "$args" in
    *"FROM system.tables"*) printf '7\n' ;;
    *"FROM superlog.local_schema_migrations"*) printf '0\n' ;;
  esac
else
  cat >/dev/null
fi
EOF
chmod +x "$TMP_DIR/bin/docker"

printf 'inherited interactive input\n' | \
  PATH="$TMP_DIR/bin:$PATH" \
  QUERY_STDIN_LOG="$QUERY_STDIN_LOG" \
  SUPERLOG_COMPOSE_PROJECT="clickhouse-stdin-test" \
  "$REPO_ROOT/scripts/clickhouse-apply-local-migrations.sh" >/dev/null

if [[ -s "$QUERY_STDIN_LOG" ]]; then
  echo "expected ClickHouse --query calls not to consume inherited stdin" >&2
  exit 1
fi

echo "clickhouse migration query stdin: ok"

DOCKER_ARGS_LOG="$TMP_DIR/docker-args.log"

# dev:portless passes a project per worktree.
PATH="$TMP_DIR/bin:$PATH" \
  QUERY_STDIN_LOG="$QUERY_STDIN_LOG" \
  DOCKER_ARGS_LOG="$DOCKER_ARGS_LOG" \
  SUPERLOG_COMPOSE_PROJECT="named-project" \
  "$REPO_ROOT/scripts/clickhouse-apply-local-migrations.sh" </dev/null >/dev/null

if ! grep -q '^compose -p named-project exec -T clickhouse' "$DOCKER_ARGS_LOG"; then
  echo "expected SUPERLOG_COMPOSE_PROJECT to select the compose project" >&2
  exit 1
fi

echo "clickhouse migration named compose project: ok"

# README quick start: no project variable, so docker compose picks its default.
: > "$DOCKER_ARGS_LOG"
env -u SUPERLOG_COMPOSE_PROJECT \
  PATH="$TMP_DIR/bin:$PATH" \
  QUERY_STDIN_LOG="$QUERY_STDIN_LOG" \
  DOCKER_ARGS_LOG="$DOCKER_ARGS_LOG" \
  "$REPO_ROOT/scripts/clickhouse-apply-local-migrations.sh" </dev/null >/dev/null

if grep -q -- ' -p ' "$DOCKER_ARGS_LOG" || ! grep -q '^compose exec -T clickhouse' "$DOCKER_ARGS_LOG"; then
  echo "expected no compose project flag when SUPERLOG_COMPOSE_PROJECT is unset" >&2
  exit 1
fi

echo "clickhouse migration default compose project: ok"
