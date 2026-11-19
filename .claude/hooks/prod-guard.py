"""PreToolUse guard: keep agents off production Azure subscriptions and Kubernetes contexts.

Local development (Colima/k3s, helm, kubectl, terraform and az against dev subscriptions) runs freely. A Bash
command is blocked when it would act on production:

- az: the subscription named by --subscription, or else the active one (az account show), is production.
  `az login`, `az account show` and `az account list` are always allowed; `az account set` to production is not.
- terraform apply/destroy/import/state/force-unlock/taint: ARM_SUBSCRIPTION_ID, or else the active az
  subscription, is production.
- helm and kubectl: the context named by --kube-context/--context, or else the current kubectl context, is
  production.

Production is any subscription (name or ID) or context listed in SDP_PROD_SUBSCRIPTIONS or SDP_PROD_KUBE_CONTEXTS
(comma separated, set in your shell, never committed), or whose name matches SDP_PROD_PATTERN (default: a
"prod" or "production" word, e.g. sdp-prod-eus, aks-production). If the target can't be determined the command
is allowed: the guard stops mistakes, it is not an access control.

Exit 2 with a message on stderr blocks the call; Claude sees the message.
"""

import json
import os
import re
import shlex
import subprocess
import sys

PATTERN = re.compile(os.environ.get("SDP_PROD_PATTERN", r"(^|[^a-z0-9])prod(uction)?([^a-z0-9]|$)"), re.I)
TF_RISKY = {"apply", "destroy", "import", "state", "force-unlock", "taint", "untaint"}


def listed(var):
    return {v.strip().lower() for v in os.environ.get(var, "").split(",") if v.strip()}


NOT_PROD = re.compile(r"(non|pre)[-_ .]?prod(uction)?", re.I)


def is_prod(values, var):
    """Listed explicitly, or the name matches the pattern once "non-prod"/"pre-prod" are taken out."""
    names = [v for v in values if v]
    return any(v.lower() in listed(var) or PATTERN.search(NOT_PROD.sub(" ", v)) for v in names)


def run(args):
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=8)
        return out.stdout.strip() if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


_active_sub = None


def active_subscription():
    global _active_sub
    if _active_sub is None:
        raw = run(["az", "account", "show", "--query", "[id, name]", "-o", "tsv"])
        _active_sub = raw.split() if raw else []
    return _active_sub


GUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)


def subscription(target):
    """[id-or-name, name] for an explicit subscription; a GUID is resolved to its name so the pattern can match."""
    if target and GUID.match(target):
        name = run(["az", "account", "show", "--subscription", target, "--query", "name", "-o", "tsv"])
        return [target, name]
    return [target]


def flag(tokens, *names):
    for i, t in enumerate(tokens):
        for n in names:
            if t == n and i + 1 < len(tokens):
                return tokens[i + 1]
            if t.startswith(n + "="):
                return t.split("=", 1)[1]
    return None


def segments(command):
    """Split a shell line into simple commands on ; && || | and newlines."""
    for part in re.split(r"&&|\|\||[;|\n]", command):
        try:
            tokens = shlex.split(part)
        except ValueError:
            tokens = part.split()
        # drop leading env assignments and wrappers
        while tokens and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]) or tokens[0] in ("sudo", "env", "time", "exec")):
            tokens = tokens[1:]
        if tokens:
            yield tokens


def check(tokens, command):
    tool = os.path.basename(tokens[0])
    args = tokens[1:]

    if tool == "az":
        if args[:1] == ["login"] or args[:2] in (["account", "show"], ["account", "list"]):
            return None
        if args[:2] == ["account", "set"]:
            target = flag(args, "--subscription", "-s", "--name", "-n")
            if is_prod(subscription(target), "SDP_PROD_SUBSCRIPTIONS"):
                return f"`az account set` to production subscription '{target}'"
            return None
        target = flag(args, "--subscription")
        subs = subscription(target) if target else active_subscription()
        if is_prod(subs, "SDP_PROD_SUBSCRIPTIONS"):
            return f"az command against production subscription '{subs[-1]}'"

    elif tool == "terraform":
        sub = [a for a in args if not a.startswith("-")]
        if sub and sub[0] in TF_RISKY:
            m = re.search(r"ARM_SUBSCRIPTION_ID=(\S+)", command)
            env_sub = m.group(1) if m else os.environ.get("ARM_SUBSCRIPTION_ID")
            subs = subscription(env_sub) if env_sub else active_subscription()
            if is_prod(subs, "SDP_PROD_SUBSCRIPTIONS"):
                return f"`terraform {sub[0]}` against production subscription '{subs[-1]}'"

    elif tool in ("helm", "kubectl"):
        if tool == "kubectl" and args[:1] == ["config"] and args[1:2] != ["use-context"]:
            return None
        if tool == "kubectl" and args[:2] == ["config", "use-context"]:
            ctx = args[2] if len(args) > 2 else ""
            if is_prod([ctx], "SDP_PROD_KUBE_CONTEXTS"):
                return f"switching kubectl to production context '{ctx}'"
            return None
        ctx = flag(args, "--kube-context", "--context") or run(["kubectl", "config", "current-context"])
        if is_prod([ctx], "SDP_PROD_KUBE_CONTEXTS"):
            return f"{tool} against production Kubernetes context '{ctx}'"
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 0
    command = (data.get("tool_input") or {}).get("command") or ""
    if not re.search(r"\b(az|terraform|helm|kubectl)\b", command):
        return 0
    for tokens in segments(command):
        reason = check(tokens, command)
        if reason:
            print(
                f"Blocked by prod-guard: {reason}. Agents never act on production; changes there go through CI "
                "and review. Use a local (Colima/k3s) or dev target, or ask the user to run it themselves.",
                file=sys.stderr,
            )
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
