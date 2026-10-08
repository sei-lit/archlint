#!/usr/bin/env python3
"""archlint: run ast-grep rules supplied by the consuming repository.

Exit codes: 0 = no problems, 1 = diagnostics with severity error, 2 = misuse,
broken environment, or a tool failure (fail closed).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

VERSION = "0.1.0"
EXIT_OK = 0
EXIT_VIOLATIONS = 1
EXIT_ERROR = 2

INSTALL_HINT = (
    "ast-grep was not found. Install it (for example `npm install -g @ast-grep/cli`,\n"
    "`brew install ast-grep` or `cargo install ast-grep --locked`), or point archlint at it\n"
    "with --ast-grep <path> or the ARCHLINT_AST_GREP environment variable."
)


class ArchlintError(Exception):
    """A usage, environment, or tool error. Reported with exit code 2."""


def run(cmd, cwd=None, input_bytes=None):
    try:
        return subprocess.run(
            cmd,
            cwd=cwd,
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as e:
        raise ArchlintError("cannot run %s: %s" % (cmd[0], e))


def git(args, cwd=None, input_bytes=None):
    proc = run(["git"] + args, cwd=cwd, input_bytes=input_bytes)
    if proc.returncode != 0:
        raise ArchlintError(
            "git %s failed: %s" % (" ".join(args[:2]), proc.stderr.decode("utf-8", "replace").strip())
        )
    return proc.stdout


def split_nul(data):
    return [os.fsdecode(p) for p in data.split(b"\0") if p]


# --- ast-grep resolution -------------------------------------------------------


def resolve_ast_grep(args):
    candidate = args.ast_grep or os.environ.get("ARCHLINT_AST_GREP") or "ast-grep"
    path = shutil.which(candidate)
    if path is None:
        raise ArchlintError(INSTALL_HINT)
    return path


def ast_grep_version(ast_grep):
    proc = run([ast_grep, "--version"])
    out = proc.stdout.decode("utf-8", "replace").strip()
    if proc.returncode != 0 or not out:
        raise ArchlintError("`%s --version` failed: %s" % (ast_grep, proc.stderr.decode("utf-8", "replace").strip()))
    return out


def verify_version(ast_grep, args):
    wanted = args.ast_grep_version or os.environ.get("ARCHLINT_AST_GREP_VERSION")
    if not wanted:
        return
    out = ast_grep_version(ast_grep)
    m = re.search(r"\d+\.\d+\.\d+\S*", out)
    actual = m.group(0) if m else out
    if actual != wanted:
        raise ArchlintError("ast-grep version mismatch: required %s, found %s (%s)" % (wanted, actual, ast_grep))


# --- repository paths ----------------------------------------------------------


def repo_root():
    out = git(["rev-parse", "--show-toplevel"]).decode("utf-8", "replace").strip()
    return os.path.realpath(out)


def resolve_config(args, root):
    """Returns (config path relative to root, config directory relative to root)."""
    if not args.config:
        raise ArchlintError("--config <sgconfig.yml> is required")
    full = os.path.realpath(args.config)
    if not os.path.isfile(full):
        raise ArchlintError("config not found: %s" % args.config)
    rel = os.path.relpath(full, root)
    if rel == ".." or rel.startswith(".." + os.sep):
        raise ArchlintError("config must be inside the repository (%s): %s" % (root, args.config))
    return rel, os.path.dirname(rel) or "."


def under(path, directory):
    return directory == "." or path == directory or path.startswith(directory + "/")


# --- diagnostics ---------------------------------------------------------------


def parse_diagnostics(proc):
    if proc.returncode not in (0, 1):
        raise ArchlintError(
            "ast-grep exited with status %d:\n%s" % (proc.returncode, proc.stderr.decode("utf-8", "replace").rstrip())
        )
    try:
        data = json.loads(proc.stdout.decode("utf-8"))
    except ValueError:
        data = None
    if not isinstance(data, list):
        raise ArchlintError(
            "ast-grep did not produce a JSON array; refusing to pass.\n%s" % proc.stderr.decode("utf-8", "replace").rstrip()
        )
    return data


def report(diagnostics, to_root_relative):
    rows = []
    for d in diagnostics:
        start = d["range"]["start"]
        rows.append(
            (
                to_root_relative(d["file"]),
                start["line"] + 1,
                start["column"] + 1,
                d.get("severity", "hint"),
                d.get("ruleId", ""),
                d.get("message", ""),
                d.get("note"),
            )
        )
    rows.sort(key=lambda r: (r[0], r[1], r[2], r[4]))
    counts = {}
    files = set()
    for path, line, col, severity, rule, message, note in rows:
        print("%s:%d:%d: %s[%s]: %s" % (path, line, col, severity, rule, message))
        if note:
            print("  note: %s" % note)
        counts[severity] = counts.get(severity, 0) + 1
        files.add(path)
    errors = counts.get("error", 0)
    others = len(rows) - errors
    sys.stderr.write(
        "archlint: %d error(s), %d other diagnostic(s) in %d file(s)\n" % (errors, others, len(files))
    )
    return EXIT_VIOLATIONS if errors else EXIT_OK


def scan(ast_grep, config_abs, targets, cwd):
    proc = run([ast_grep, "scan", "--config", config_abs, "--json=compact"] + targets, cwd=cwd)
    return parse_diagnostics(proc)


# --- commands ------------------------------------------------------------------


def check_staged(ast_grep, root, config_rel, config_dir):
    staged = split_nul(
        git(["diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"], cwd=root)
    )
    targets = [p for p in staged if under(p, config_dir)]
    if not targets:
        return EXIT_OK

    indexed = split_nul(git(["ls-files", "--cached", "-z", "--", config_dir], cwd=root))
    rule_files = [p for p in indexed if p.endswith((".yml", ".yaml")) and under(p, config_dir)]
    if config_rel not in indexed:
        raise ArchlintError("config is not in the git index (git add it first): %s" % config_rel)

    tmp = tempfile.mkdtemp(prefix="archlint.")
    try:
        tmp_real = os.path.realpath(tmp)
        export = sorted(set(targets) | set(rule_files))
        git(
            ["checkout-index", "--prefix=%s/" % tmp_real, "-z", "--stdin"],
            cwd=root,
            input_bytes=b"\0".join(os.fsencode(p) for p in export) + b"\0",
        )
        tmp_config_dir = os.path.join(tmp_real, config_dir)
        diagnostics = scan(
            ast_grep,
            os.path.join(tmp_real, config_rel),
            [os.path.join(tmp_real, p) for p in targets],
            tmp_config_dir,
        )

        def to_root_relative(file):
            full = file if os.path.isabs(file) else os.path.join(tmp_config_dir, file)
            return os.path.relpath(os.path.realpath(full), tmp_real)

        return report(diagnostics, to_root_relative)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def check_worktree(ast_grep, root, config_rel, config_dir, paths):
    config_dir_abs = os.path.join(root, config_dir)
    targets = [os.path.abspath(p) for p in paths] if paths else [config_dir_abs]
    diagnostics = scan(ast_grep, os.path.join(root, config_rel), targets, config_dir_abs)

    def to_root_relative(file):
        full = file if os.path.isabs(file) else os.path.join(config_dir_abs, file)
        return os.path.relpath(os.path.realpath(full), root)

    return report(diagnostics, to_root_relative)


def cmd_check(args):
    ast_grep = resolve_ast_grep(args)
    verify_version(ast_grep, args)
    root = repo_root()
    config_rel, config_dir = resolve_config(args, root)
    if args.staged:
        if args.paths:
            raise ArchlintError("--staged does not take paths")
        return check_staged(ast_grep, root, config_rel, config_dir)
    return check_worktree(ast_grep, root, config_rel, config_dir, args.paths)


def cmd_test(args):
    ast_grep = resolve_ast_grep(args)
    verify_version(ast_grep, args)
    if not args.config:
        raise ArchlintError("--config <sgconfig.yml> is required")
    if not os.path.isfile(args.config):
        raise ArchlintError("config not found: %s" % args.config)
    try:
        return subprocess.call([ast_grep, "test", "--config", os.path.abspath(args.config), "--skip-snapshot-tests"])
    except OSError as e:
        raise ArchlintError("cannot run %s: %s" % (ast_grep, e))


def cmd_doctor(args):
    ast_grep = resolve_ast_grep(args)
    verify_version(ast_grep, args)
    print("archlint %s" % VERSION)
    print("ast-grep: %s" % ast_grep)
    print("version: %s" % ast_grep_version(ast_grep))
    return EXIT_OK


def build_parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--ast-grep", metavar="PATH", help="ast-grep executable (default: $ARCHLINT_AST_GREP, then PATH)")
    common.add_argument(
        "--ast-grep-version",
        metavar="X.Y.Z",
        help="require this exact ast-grep version (default: $ARCHLINT_AST_GREP_VERSION)",
    )
    parser = argparse.ArgumentParser(prog="archlint", description="Run ast-grep rules supplied by the repository.")
    parser.add_argument("--version", action="version", version="archlint " + VERSION)
    sub = parser.add_subparsers(dest="command", metavar="<command>")
    sub.required = True

    check = sub.add_parser("check", parents=[common], help="scan files with the rules")
    check.add_argument("--config", metavar="SGCONFIG", help="ast-grep sgconfig.yml inside the repository")
    check.add_argument("--staged", action="store_true", help="scan the staged (index) content instead of the working tree")
    check.add_argument("paths", nargs="*", help="files or directories to scan (default: the config directory)")
    check.set_defaults(func=cmd_check)

    test = sub.add_parser("test", parents=[common], help="run the rule tests (ast-grep test)")
    test.add_argument("--config", metavar="SGCONFIG", help="ast-grep sgconfig.yml")
    test.set_defaults(func=cmd_test)

    doctor = sub.add_parser("doctor", parents=[common], help="show the ast-grep in use")
    doctor.set_defaults(func=cmd_doctor)
    return parser


def main(argv):
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except ArchlintError as e:
        sys.stderr.write("archlint: %s\n" % e)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
