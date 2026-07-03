"""Weekly executive summarizer.

Pulls the week's findings and cost rows from DynamoDB, renders the versioned
prompt (prompts are code — they live in the repo and get reviewed like it),
asks Claude on Bedrock via the Converse API, and publishes the summary to SNS.
"""

import json
import os
from datetime import date, timedelta
from pathlib import Path

import boto3
from boto3.dynamodb.conditions import Key

from shared import config, logger

PROMPT_PATH = Path(__file__).parent / "prompts" / "executive_summary_v1.txt"
FINDING_TYPES = ["IDLE_EC2", "ORPHANED_STORAGE", "TAG_COMPLIANCE"]
MAX_OUTPUT_TOKENS = 800


def _week_of_findings(table, since: str) -> list[dict]:
    items = []
    for finding_type in FINDING_TYPES:
        response = table.query(
            KeyConditionExpression=Key("pk").eq(f"FINDING#{finding_type}") & Key("sk").gte(since)
        )
        items.extend(response["Items"])
    return items


def _week_of_costs(table, days: list[str]) -> list[dict]:
    items = []
    for day in days:
        response = table.query(KeyConditionExpression=Key("pk").eq(f"COST#{day}"))
        items.extend(response["Items"])
    return items


def _render_prompt(findings: list[dict], costs: list[dict]) -> str:
    data = {
        "findings": findings,
        "daily_costs_by_service": costs,
    }
    template = PROMPT_PATH.read_text()
    return template.replace("{data}", json.dumps(data, default=str, indent=2))


def _summarize(bedrock, prompt: str) -> str:
    response = bedrock.converse(
        modelId=os.environ["BEDROCK_MODEL_ID"],
        messages=[{"role": "user", "content": [{"text": prompt}]}],
        inferenceConfig={"maxTokens": MAX_OUTPUT_TOKENS},
    )
    return response["output"]["message"]["content"][0]["text"]


def run(ddb_resource=None, bedrock_client=None, sns_client=None, today: date | None = None) -> dict:
    ddb = ddb_resource or boto3.resource("dynamodb")
    bedrock = bedrock_client or boto3.client("bedrock-runtime")
    sns = sns_client or boto3.client("sns")

    today = today or date.today()
    since = (today - timedelta(days=7)).isoformat()
    days = [(today - timedelta(days=i)).isoformat() for i in range(1, 8)]

    table = ddb.Table(config.table_name())
    findings = _week_of_findings(table, since)
    costs = _week_of_costs(table, days)

    summary = _summarize(bedrock, _render_prompt(findings, costs))

    sns.publish(
        TopicArn=os.environ["REPORT_TOPIC_ARN"],
        Subject=f"FinOps weekly report — {today.isoformat()}",
        Message=summary,
    )
    logger.info(
        "weekly summary published",
        findings=len(findings),
        cost_rows=len(costs),
        summary_chars=len(summary),
    )
    return {"findings": len(findings), "cost_rows": len(costs), "published": True}


def lambda_handler(event, context):
    return run()
