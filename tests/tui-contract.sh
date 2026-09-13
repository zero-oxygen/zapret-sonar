#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

grep -q '^MENU_CHECK=' "$PROJECT_DIR/zapret-sonar-tui"
grep -q '^            "$MENU_CHECK" \\' "$PROJECT_DIR/zapret-sonar-tui"
grep -q '^            "$MENU_CHECK")' "$PROJECT_DIR/zapret-sonar-tui"
grep -Fq "header+=\$'\\n'\"сейчас: \$cur\"" "$PROJECT_DIR/zapret-sonar-tui"
grep -q '^              --header-first \\' "$PROJECT_DIR/zapret-sonar-tui"

printf 'PASS: TUI menu dispatch and multiline strategy header contracts hold\n'
