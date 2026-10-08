#!/bin/bash
# archlint test suite. Runs against throwaway git repositories that carry their
# own sgconfig.yml and rules. ast-grep must be on PATH (or set ARCHLINT_AST_GREP).
#
# USAGE: tests/run.sh [test-name-filter]
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHLINT_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
ARCHLINT="${ARCHLINT_ROOT}/bin/archlint"
FILTER="${1:-}"

PASS=0
FAIL=0

if ! command -v "${ARCHLINT_AST_GREP:-ast-grep}" >/dev/null 2>&1; then
    echo "ast-grep not found; install it or set ARCHLINT_AST_GREP" >&2
    exit 1
fi

# --- harness ---------------------------------------------------------------------

fail() { printf '    FAIL: %s\n' "$*"; CASE_FAILED=1; }

assert_eq() {
    [ "$1" = "$2" ] || fail "expected [$2], got [$1] ${3:+($3)}"
}

assert_contains() {
    case "$1" in *"$2"*) ;; *) fail "expected output to contain [$2] ${3:+($3)}"$'\n'"--- output ---"$'\n'"$1" ;; esac
}

run_test() {
    local name="$1" rc
    if [ -n "${FILTER}" ]; then
        case "${name}" in *"${FILTER}"*) ;; *) return 0 ;; esac
    fi
    SANDBOX="$(mktemp -d)"
    printf '%s\n' "${name}"
    # The subshell isolates cwd and environment changes; assertion failures are
    # carried out through the exit code.
    (
        setup_sandbox
        cd "${SANDBOX}/repo" || exit 1
        CASE_FAILED=0
        "${name}"
        exit "${CASE_FAILED}"
    )
    rc=$?
    if [ "${rc}" -eq 0 ]; then
        PASS=$((PASS + 1))
        printf '    ok\n'
    else
        FAIL=$((FAIL + 1))
    fi
    rm -rf "${SANDBOX}"
}

# Runs archlint, capturing stdout in OUT, stderr in ERR and the exit code in RC.
archlint() {
    OUT="$("${ARCHLINT}" "$@" 2>"${SANDBOX}/stderr")"
    RC=$?
    ERR="$(cat "${SANDBOX}/stderr")"
}

# A repository whose app/ directory holds the ast-grep project: a config, an
# error rule (Japanese literal passed to Text) and a warning rule (TODO comment).
setup_sandbox() {
    export HOME="${SANDBOX}/home"
    export TMPDIR="${SANDBOX}/tmp"
    mkdir -p "${HOME}" "${TMPDIR}" "${SANDBOX}/repo/app/rules" "${SANDBOX}/repo/app/Views"
    cd "${SANDBOX}/repo" || exit 1
    git init -q -b main
    git config user.email test@example.com
    git config user.name test

    cat > app/sgconfig.yml <<'YAML'
ruleDirs:
  - rules
testConfigs:
  - testDir: rule-tests
YAML
    cat > app/rules/no-japanese-text-literal.yml <<'YAML'
id: no-japanese-text-literal
language: swift
severity: error
message: Do not pass a Japanese literal to Text.
note: Use a localized string.
files:
  - Views/**
rule:
  pattern: Text($ARG)
constraints:
  ARG:
    regex: '[ぁ-んァ-ン一-龥]'
YAML
    cat > app/rules/todo-comment.yml <<'YAML'
id: todo-comment
language: swift
severity: warning
message: Resolve the TODO.
rule:
  kind: comment
  regex: 'TODO'
YAML
    git add -A
    git commit -q -m init
}

write_violation() { printf 'import SwiftUI\n\nlet v = Text("こんにちは")\n' > "$1"; }
write_clean() { printf 'import SwiftUI\n\nlet v = Text("hello")\n' > "$1"; }

# --- check --staged ---------------------------------------------------------------

test_staged_violation_reports_one_based_position() {
    write_violation app/Views/A.swift
    git add app/Views/A.swift
    archlint check --config app/sgconfig.yml --staged
    assert_eq "${RC}" "1"
    assert_contains "${OUT}" "app/Views/A.swift:3:9: error[no-japanese-text-literal]: Do not pass a Japanese literal to Text."
    assert_contains "${OUT}" "  note: Use a localized string."
    assert_contains "${ERR}" "1 error(s)"
    assert_eq "$(find "${TMPDIR}" -mindepth 1 | wc -l | tr -d ' ')" "0" "temporary directory removed"
}

test_staged_symlink_is_skipped_not_followed() {
    write_violation outside.swift
    ln -s ../../outside.swift app/Views/Link.swift
    git add app/Views/Link.swift
    archlint check --config app/sgconfig.yml --staged
    assert_eq "${RC}" "0"
    assert_contains "${ERR}" "skipped 1 non-regular file(s)"
    assert_contains "${ERR}" "app/Views/Link.swift"
}

test_staged_uses_config_from_index_even_if_deleted_in_worktree() {
    write_violation app/Views/A.swift
    git add app/Views/A.swift
    rm app/sgconfig.yml
    archlint check --config app/sgconfig.yml --staged
    assert_eq "${RC}" "1"
    assert_contains "${OUT}" "app/Views/A.swift:3:9: error[no-japanese-text-literal]"
}

# A fake ast-grep whose scan prints $FAKE_OUT and exits with $FAKE_RC.
write_fake_ast_grep() {
    cat > "${SANDBOX}/fake-ast-grep" <<'SH'
#!/bin/bash
if [ "$1" = "--version" ]; then echo "ast-grep 0.0.0"; exit 0; fi
printf '%s' "${FAKE_OUT}"
exit "${FAKE_RC}"
SH
    chmod +x "${SANDBOX}/fake-ast-grep"
}

test_exit_1_without_error_diagnostics_is_a_tool_failure() {
    write_fake_ast_grep
    write_clean app/Views/A.swift
    git add app/Views/A.swift
    FAKE_OUT='[]' FAKE_RC=1 archlint check --config app/sgconfig.yml --staged --ast-grep "${SANDBOX}/fake-ast-grep"
    assert_eq "${RC}" "2"
}

test_malformed_diagnostic_is_a_tool_failure() {
    write_fake_ast_grep
    write_clean app/Views/A.swift
    git add app/Views/A.swift
    FAKE_OUT='[{}]' FAKE_RC=1 archlint check --config app/sgconfig.yml --staged --ast-grep "${SANDBOX}/fake-ast-grep"
    assert_eq "${RC}" "2"
    assert_contains "${ERR}" "unexpected"
}

test_many_staged_files_are_scanned_in_chunks() {
    local i
    for i in $(seq 1 450); do write_violation "app/Views/F${i}.swift"; done
    git add app/Views
    archlint check --config app/sgconfig.yml --staged
    assert_eq "${RC}" "1"
    assert_contains "${ERR}" "450 error(s)"
}

test_multiline_note_is_indented_on_every_line() {
    python3 - app/rules/no-japanese-text-literal.yml <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("note: Use a localized string.\n", "note: |\n  First line.\n  Second line.\n")
open(p, "w").write(s)
PY
    git add app/rules/no-japanese-text-literal.yml
    write_violation app/Views/A.swift
    git add app/Views/A.swift
    archlint check --config app/sgconfig.yml --staged
    assert_eq "${RC}" "1"
    assert_contains "${OUT}" "  note: First line."
    assert_contains "${OUT}" "        Second line."
}

test_staged_clean_file_passes() {
    write_clean app/Views/A.swift
    git add app/Views/A.swift
    archlint check --config app/sgconfig.yml --staged
    assert_eq "${RC}" "0"
    assert_eq "${OUT}" ""
}

test_staged_checks_index_not_worktree_violation_only_in_worktree() {
    write_clean app/Views/A.swift
    git add app/Views/A.swift
    write_violation app/Views/A.swift
    archlint check --config app/sgconfig.yml --staged
    assert_eq "${RC}" "0"
}

test_staged_checks_index_not_worktree_violation_only_in_index() {
    write_violation app/Views/A.swift
    git add app/Views/A.swift
    write_clean app/Views/A.swift
    archlint check --config app/sgconfig.yml --staged
    assert_eq "${RC}" "1"
    assert_contains "${OUT}" "app/Views/A.swift:3:9: error["
}

test_staged_path_with_spaces() {
    mkdir -p "app/Views/My Views"
    write_violation "app/Views/My Views/A B.swift"
    git add -A
    archlint check --config app/sgconfig.yml --staged
    assert_eq "${RC}" "1"
    assert_contains "${OUT}" "app/Views/My Views/A B.swift:3:9: error["
}

test_staged_renamed_file_is_checked() {
    write_clean app/Views/Old.swift
    git add -A
    git commit -q -m old
    git mv app/Views/Old.swift app/Views/New.swift
    write_violation app/Views/New.swift
    git add -A
    archlint check --config app/sgconfig.yml --staged
    assert_eq "${RC}" "1"
    assert_contains "${OUT}" "app/Views/New.swift:3:9: error["
}

test_staged_deleted_file_is_not_checked() {
    write_violation app/Views/Gone.swift
    git add -A
    git commit -q -m violating
    git rm -q app/Views/Gone.swift
    archlint check --config app/sgconfig.yml --staged
    assert_eq "${RC}" "0"
    assert_eq "${OUT}" ""
}

test_staged_outside_config_directory_is_ignored() {
    mkdir -p other
    write_violation other/A.swift
    git add -A
    archlint check --config app/sgconfig.yml --staged
    assert_eq "${RC}" "0"
    assert_eq "${OUT}" ""
}

test_staged_without_swift_files_passes() {
    printf 'notes\n' > app/notes.txt
    git add -A
    archlint check --config app/sgconfig.yml --staged
    assert_eq "${RC}" "0"
    assert_eq "${OUT}" ""
}

test_staged_rule_change_is_applied_from_index() {
    cat > app/rules/no-print.yml <<'YAML'
id: no-print
language: swift
severity: error
message: Do not call print.
rule:
  pattern: print($$$)
YAML
    printf 'print("x")\n' > app/Views/P.swift
    git add -A
    rm app/rules/no-print.yml
    archlint check --config app/sgconfig.yml --staged
    assert_eq "${RC}" "1"
    assert_contains "${OUT}" "app/Views/P.swift:1:1: error[no-print]: Do not call print."
}

test_staged_broken_rule_fails_closed() {
    printf 'id: [\n' > app/rules/broken.yml
    write_clean app/Views/A.swift
    git add -A
    archlint check --config app/sgconfig.yml --staged
    assert_eq "${RC}" "2"
    assert_contains "${ERR}" "broken.yml"
}

test_staged_warning_only_exits_zero_and_is_shown() {
    printf 'import SwiftUI\n// TODO: later\n' > app/Views/T.swift
    git add -A
    archlint check --config app/sgconfig.yml --staged
    assert_eq "${RC}" "0"
    assert_contains "${OUT}" "app/Views/T.swift:2:1: warning[todo-comment]: Resolve the TODO."
    assert_contains "${ERR}" "0 error(s), 1 other"
}

test_config_outside_repository_is_rejected() {
    mkdir -p "${SANDBOX}/elsewhere/rules"
    cp app/sgconfig.yml "${SANDBOX}/elsewhere/"
    archlint check --config "${SANDBOX}/elsewhere/sgconfig.yml" --staged
    assert_eq "${RC}" "2"
    assert_contains "${ERR}" "inside the repository"
}

test_missing_config_is_rejected() {
    archlint check --config app/missing.yml --staged
    assert_eq "${RC}" "2"
}

# --- ast-grep resolution ------------------------------------------------------------

test_version_mismatch_is_rejected() {
    write_clean app/Views/A.swift
    git add -A
    archlint check --config app/sgconfig.yml --staged --ast-grep-version 0.0.1
    assert_eq "${RC}" "2"
    assert_contains "${ERR}" "version mismatch"
}

test_version_match_is_accepted_via_option_and_environment() {
    local actual
    actual="$("${ARCHLINT_AST_GREP:-ast-grep}" --version | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
    write_clean app/Views/A.swift
    git add -A
    archlint check --config app/sgconfig.yml --staged --ast-grep-version "${actual}"
    assert_eq "${RC}" "0" "option"
    ARCHLINT_AST_GREP_VERSION="${actual}" archlint check --config app/sgconfig.yml --staged
    assert_eq "${RC}" "0" "environment"
    ARCHLINT_AST_GREP_VERSION="0.0.1" archlint check --config app/sgconfig.yml --staged
    assert_eq "${RC}" "2" "environment mismatch"
}

test_ast_grep_missing_from_path_is_rejected() {
    local bin="${SANDBOX}/bin"
    mkdir -p "${bin}"
    ln -s "$(command -v git)" "${bin}/git"
    ln -s "$(command -v dirname)" "${bin}/dirname"
    ln -s "$(python3 -c 'import sys; print(sys.executable)')" "${bin}/python3"
    write_clean app/Views/A.swift
    git add -A
    OUT="$(env -u ARCHLINT_AST_GREP PATH="${bin}" /bin/bash "${ARCHLINT}" check --config app/sgconfig.yml --staged 2>"${SANDBOX}/stderr")"
    RC=$?
    ERR="$(cat "${SANDBOX}/stderr")"
    assert_eq "${RC}" "2"
    assert_contains "${ERR}" "ast-grep was not found"
}

test_ast_grep_option_pointing_nowhere_is_rejected() {
    archlint doctor --ast-grep "${SANDBOX}/nowhere/ast-grep"
    assert_eq "${RC}" "2"
    assert_contains "${ERR}" "ast-grep was not found"
}

test_doctor_shows_path_and_version() {
    archlint doctor
    assert_eq "${RC}" "0"
    assert_contains "${OUT}" "ast-grep:"
    assert_contains "${OUT}" "version: ast-grep"
}

# --- check (working tree) ------------------------------------------------------------

test_worktree_check_with_paths() {
    write_violation app/Views/Bad.swift
    write_clean app/Views/Good.swift
    archlint check --config app/sgconfig.yml app/Views/Good.swift
    assert_eq "${RC}" "0" "clean path"
    archlint check --config app/sgconfig.yml app/Views/Bad.swift
    assert_eq "${RC}" "1" "violating path"
    assert_contains "${OUT}" "app/Views/Bad.swift:3:9: error["
}

test_worktree_check_defaults_to_config_directory() {
    write_violation app/Views/Bad.swift
    archlint check --config app/sgconfig.yml
    assert_eq "${RC}" "1"
    assert_contains "${OUT}" "app/Views/Bad.swift:3:9: error["
}

test_worktree_check_from_subdirectory_reports_root_relative_paths() {
    write_violation app/Views/Bad.swift
    cd app || return
    archlint check --config sgconfig.yml Views/Bad.swift
    assert_eq "${RC}" "1"
    assert_contains "${OUT}" "app/Views/Bad.swift:3:9: error["
}

test_worktree_check_broken_rule_fails_closed() {
    printf 'id: [\n' > app/rules/broken.yml
    write_clean app/Views/A.swift
    archlint check --config app/sgconfig.yml app/Views/A.swift
    assert_eq "${RC}" "2"
}

# --- test ------------------------------------------------------------------------------

write_rule_test() {
    mkdir -p app/rule-tests
    cat > app/rule-tests/no-japanese-text-literal-test.yml <<YAML
id: no-japanese-text-literal
valid:
  - Text("hello")
invalid:
  - ${1}
YAML
}

test_test_command_runs_rule_tests() {
    write_rule_test 'Text("こんにちは")'
    archlint test --config app/sgconfig.yml
    assert_eq "${RC}" "0"
    assert_contains "${OUT}${ERR}" "no-japanese-text-literal"
}

test_test_command_returns_failure_exit_code() {
    write_rule_test 'Text("hello")'
    archlint test --config app/sgconfig.yml
    [ "${RC}" -ne 0 ] || fail "expected a non-zero exit code when an invalid case does not match"
}

for t in \
    test_staged_symlink_is_skipped_not_followed \
    test_staged_uses_config_from_index_even_if_deleted_in_worktree \
    test_exit_1_without_error_diagnostics_is_a_tool_failure \
    test_malformed_diagnostic_is_a_tool_failure \
    test_many_staged_files_are_scanned_in_chunks \
    test_multiline_note_is_indented_on_every_line \
    test_staged_violation_reports_one_based_position \
    test_staged_clean_file_passes \
    test_staged_checks_index_not_worktree_violation_only_in_worktree \
    test_staged_checks_index_not_worktree_violation_only_in_index \
    test_staged_path_with_spaces \
    test_staged_renamed_file_is_checked \
    test_staged_deleted_file_is_not_checked \
    test_staged_outside_config_directory_is_ignored \
    test_staged_without_swift_files_passes \
    test_staged_rule_change_is_applied_from_index \
    test_staged_broken_rule_fails_closed \
    test_staged_warning_only_exits_zero_and_is_shown \
    test_config_outside_repository_is_rejected \
    test_missing_config_is_rejected \
    test_version_mismatch_is_rejected \
    test_version_match_is_accepted_via_option_and_environment \
    test_ast_grep_missing_from_path_is_rejected \
    test_ast_grep_option_pointing_nowhere_is_rejected \
    test_doctor_shows_path_and_version \
    test_worktree_check_with_paths \
    test_worktree_check_defaults_to_config_directory \
    test_worktree_check_from_subdirectory_reports_root_relative_paths \
    test_worktree_check_broken_rule_fails_closed \
    test_test_command_runs_rule_tests \
    test_test_command_returns_failure_exit_code \
; do
    run_test "${t}"
done

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
