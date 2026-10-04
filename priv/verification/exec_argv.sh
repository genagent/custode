#!/bin/sh
stdout_path=$1
stderr_path=$2
stdin_mode=$3
shift 3

case "$stdin_mode" in
  null) exec "$@" </dev/null >"$stdout_path" 2>"$stderr_path" ;;
  inherit) exec "$@" >"$stdout_path" 2>"$stderr_path" ;;
  *) exit 125 ;;
esac
