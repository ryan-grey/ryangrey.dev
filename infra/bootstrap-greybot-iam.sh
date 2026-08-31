#!/usr/bin/env bash
#
# The last CloudShell paste, for real this time.
#
# One-time bootstrap that brings ryangrey-greybot-role under ryangrey-infra's management,
# so greyBot IAM changes stop needing an admin session. After this runs, every future
# greybot policy change is `aws --profile infra` from the Mac.
#
# ---------------------------------------------------------------------------
# WHY THIS CANNOT RUN FROM THE MAC
#
# Nothing on that machine has IAM write. ryan-cli has none by design; ryangrey-infra's
# write is scoped to role/ryangrey-app/*, and it cannot edit its own policy either. That
# is the bootstrap problem: no credential can grant itself the thing it lacks. One admin
# session is unavoidable — this is it, and it is the only one.
# ---------------------------------------------------------------------------
#
# WHAT IT CHANGES, and why each piece is safe:
#
#   1. ryangrey-app-boundary gains sns:Publish and lambda:InvokeFunction.
#      A boundary is a CEILING, not a grant — nothing gains a permission from this, it
#      only stops being impossible to grant. Both are needed because step 2 attaches this
#      boundary to greybot, which already uses lambda:InvokeFunction for the /progress
#      deferral and is about to need sns:Publish for the health alerts.
#
#   2. The boundary is attached to ryangrey-greybot-role.
#      This is the step with teeth, and README-iam.md flags it: attaching a boundary that
#      is missing an action breaks a live app exactly like a missing grant does. So the
#      script checks every action in greybot-runtime against the boundary FIRST and
#      refuses to attach if anything falls outside, then invokes the live function
#      afterwards to prove it still works.
#
#   3. ryangrey-infra gains iam:PutRolePolicy + iam:DeleteRolePolicy on that ONE role.
#      This is the actual grant, and step 2 is what makes it safe. Without a boundary it
#      would be a clean path to admin: infra already holds lambda:* and iam:PassRole to
#      lambda, so it could write Action:"*" onto greybot-role and run anything as it.
#      With the boundary attached, everything infra can grant is capped by the ceiling —
#      and infra cannot remove the boundary, because DenyIamEscalationOutright already
#      denies both boundary actions and an explicit Deny beats any Allow.
#
# NOT granted: iam:DeleteRole, iam:UpdateAssumeRolePolicy, iam:AttachRolePolicy. Writing
# the inline policy is the whole job; the rest is surface for no benefit.
#
# ROLLBACK, if any of this turns out to be wrong (admin, from here):
#   aws iam delete-role-permissions-boundary --role-name ryangrey-greybot-role
#   aws iam put-role-policy --role-name ryangrey-infra --policy-name ryangrey-infra \
#     --policy-document file://<the previous ryangrey-infra-policy.json>
#
# Idempotent: safe to re-run.
set -euo pipefail

REGION=us-east-1
ROLE=ryangrey-greybot-role
INFRA=ryangrey-infra
FN=ryangrey-greybot
RAW=https://raw.githubusercontent.com/ryan-grey/ryangrey.dev/main/infra
ACCT="$(aws sts get-caller-identity --query Account --output text)"
BOUNDARY="arn:aws:iam::$ACCT:policy/ryangrey-app-boundary"

echo "Account:  $ACCT"
echo "Identity: $(aws sts get-caller-identity --query Arn --output text)"
echo "Source:   $RAW"
echo

# ---------------------------------------------------------------- fetch
# Straight from the public repo, so there is exactly one copy of each policy document and
# no chance of a pasted heredoc drifting from the file that is supposed to be the source
# of truth. Read them before running if you like — they are the two files below.
echo "==> Fetching policy documents"
curl -fsSL -o /tmp/boundary.json "$RAW/ryangrey-app-boundary.json"
curl -fsSL -o /tmp/infra.json    "$RAW/ryangrey-infra-policy.json"
python3 -c 'import json,sys; [json.load(open(f)) for f in ("/tmp/boundary.json","/tmp/infra.json")]' \
  || { echo "    [!!] not valid JSON — is the push landed?"; exit 1; }
grep -q '"sns:Publish"' /tmp/boundary.json \
  || { echo "    [!!] boundary is missing sns:Publish — push ryangrey.dev first"; exit 1; }
grep -q 'ManageGreybotRolePolicyOnly' /tmp/infra.json \
  || { echo "    [!!] infra policy is missing the new sid — push ryangrey.dev first"; exit 1; }
echo "    [ok] both documents fetched and contain the new statements"

# ---------------------------------------------------------------- 1. boundary version
echo
echo "==> Boundary policy"
# Managed policies hold at most five versions and refuse the sixth, so prune the oldest
# non-default before adding. Doing this lazily is how a routine policy update turns into
# a LimitExceeded at the least convenient moment.
COUNT=$(aws iam list-policy-versions --policy-arn "$BOUNDARY" \
  --query 'length(Versions)' --output text)
if [ "$COUNT" -ge 5 ]; then
  OLDEST=$(aws iam list-policy-versions --policy-arn "$BOUNDARY" \
    --query 'sort_by(Versions[?IsDefaultVersion==`false`], &CreateDate)[0].VersionId' \
    --output text)
  echo "    [--] pruning oldest version $OLDEST ($COUNT of 5 used)"
  aws iam delete-policy-version --policy-arn "$BOUNDARY" --version-id "$OLDEST"
fi
aws iam create-policy-version --policy-arn "$BOUNDARY" \
  --policy-document file:///tmp/boundary.json --set-as-default >/dev/null
echo "    [ok] ryangrey-app-boundary updated (+sns:Publish, +lambda:InvokeFunction)"

# ---------------------------------------------------------------- 2. attach, carefully
echo
echo "==> Checking the boundary covers what greyBot already does"
# The failure this prevents: attach a ceiling that omits one action greybot's live policy
# depends on, and the bot breaks silently on the next poll with a correct-looking policy
# still in place. Compared service-by-service because the boundary is written as service
# wildcards (logs:*) while the runtime policy is written as specific actions.
aws iam get-role-policy --role-name $ROLE --policy-name greybot-runtime \
  --query 'PolicyDocument' > /tmp/greybot-runtime.json
python3 - <<'PY' || exit 1
import json, sys, fnmatch
runtime = json.load(open("/tmp/greybot-runtime.json"))
ceiling = json.load(open("/tmp/boundary.json"))
allowed = []
for s in ceiling["Statement"]:
    if s["Effect"] == "Allow":
        a = s["Action"]
        allowed += [a] if isinstance(a, str) else a
missing = []
for s in runtime["Statement"]:
    if s.get("Effect") != "Allow":
        continue
    acts = s["Action"]
    for act in ([acts] if isinstance(acts, str) else acts):
        if not any(fnmatch.fnmatch(act, pat) for pat in allowed):
            missing.append((s.get("Sid"), act))
if missing:
    print("    [!!] the boundary does NOT cover:")
    for sid, act in missing:
        print(f"         {act}   (sid {sid})")
    print("    Attaching it would break the live bot. Add these to the boundary first.")
    sys.exit(1)
print("    [ok] every action in greybot-runtime is inside the ceiling")
PY

echo
echo "==> Attaching the boundary"
aws iam put-role-permissions-boundary --role-name $ROLE --permissions-boundary "$BOUNDARY"
echo "    [ok] $ROLE is now capped by ryangrey-app-boundary"

# ---------------------------------------------------------------- 3. the grant
echo
echo "==> Widening ryangrey-infra"
aws iam put-role-policy --role-name $INFRA --policy-name $INFRA \
  --policy-document file:///tmp/infra.json
echo "    [ok] ManageGreybotRolePolicyOnly added"

# ---------------------------------------------------------------- verify
echo
echo "==> Verifying"
sleep 10   # IAM is eventually consistent; a simulate run too soon reads the old policy
aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::$ACCT:role/$INFRA" \
  --action-names iam:PutRolePolicy \
  --resource-arns "arn:aws:iam::$ACCT:role/$ROLE" \
  --query 'EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision}' --output table

echo
echo "    boundary on $ROLE:"
aws iam get-role --role-name $ROLE --query 'Role.PermissionsBoundary' --output table

# The live check. Everything above can look right while the bot is broken, and the only
# thing that settles it is the function actually running.
echo
echo "==> Smoke test: invoking the live bot"
aws lambda invoke --function-name $FN --region $REGION /tmp/out.json >/dev/null
if grep -q '"ok": *true' /tmp/out.json; then
  echo "    [ok] greyBot still runs under the boundary"
else
  echo "    [!!] greyBot returned something unexpected — READ THIS BEFORE LEAVING:"
  cat /tmp/out.json
  echo
  echo "    Roll the boundary back with:"
  echo "      aws iam delete-role-permissions-boundary --role-name $ROLE"
  exit 1
fi

cat <<EOF

Done, and this is the last time CloudShell is needed for greyBot.

Everything else now runs from the Mac as \`aws --profile infra\`. Tell Claude it is done and
it can finish the alerts unattended:

  bash ~/Documents/scrambled-raid-bot/infra/grant-alerts.sh
  cd ~/Documents/scrambled-raid-bot && scripts/deploy.sh
EOF
