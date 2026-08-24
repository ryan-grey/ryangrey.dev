"""
SNS -> SES alert forwarder for ryangrey.dev.

Subscribed to the ryangrey-dev-alerts SNS topic. Formats CloudWatch alarm
payloads into readable mail and sends them via SES from a DKIM-signed
address on a domain we control.

Why this exists: SNS's own email sender is shared infrastructure, and mail
from it was never delivered to the target Gmail address (four subscribe
attempts, zero arrivals, while other AWS senders got through). Sending from
an authenticated domain identity sidesteps that entirely.

Env:
  SENDER     From address, e.g. alerts@ryangrey.dev
  RECIPIENT  Destination address
"""
import json
import os

import boto3

ses = boto3.client("sesv2")


def handler(event, context):
    record = event["Records"][0]["Sns"]
    raw = record["Message"]
    subject = record.get("Subject") or "ryangrey.dev alert"

    try:
        msg = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        msg = None

    if isinstance(msg, dict) and "AlarmName" in msg:
        state = msg.get("NewStateValue", "UNKNOWN")
        subject = f"[{state}] {msg['AlarmName']}"
        lines = [
            f"Alarm:  {msg.get('AlarmName')}",
            f"State:  {msg.get('OldStateValue')} -> {state}",
            f"Time:   {msg.get('StateChangeTime')}",
            f"Region: {msg.get('Region')}",
            "",
            f"Reason: {msg.get('NewStateReason')}",
        ]
        trigger = msg.get("Trigger") or {}
        if trigger:
            lines += [
                "",
                f"Metric: {trigger.get('Namespace')}/{trigger.get('MetricName')}",
                f"Rule:   {trigger.get('Statistic')} {trigger.get('ComparisonOperator')} "
                f"{trigger.get('Threshold')} for {trigger.get('EvaluationPeriods')}"
                f" x {trigger.get('Period')}s",
            ]
        body = "\n".join(lines)
    else:
        body = raw if isinstance(raw, str) else json.dumps(msg, indent=2)

    ses.send_email(
        FromEmailAddress=os.environ["SENDER"],
        Destination={"ToAddresses": [os.environ["RECIPIENT"]]},
        Content={
            "Simple": {
                "Subject": {"Data": subject[:200]},
                "Body": {"Text": {"Data": body}},
            }
        },
    )
    return {"delivered": True}
