"""moto covers DynamoDB and SNS; the Bedrock Converse call is stubbed with a
fake client so the test controls the model's output text."""

from datetime import date
from decimal import Decimal

import boto3
import pytest

from bedrock_reporter import summarizer
from tests.conftest import TABLE_NAME

TODAY = date(2026, 7, 3)


class FakeBedrock:
    def __init__(self, reply="HEADLINE: $42/month in savings identified."):
        self.reply = reply
        self.prompts = []

    def converse(self, modelId, messages, inferenceConfig):
        self.prompts.append(messages[0]["content"][0]["text"])
        return {"output": {"message": {"content": [{"text": self.reply}]}}}


@pytest.fixture
def report_env(monkeypatch, ddb):
    sns = boto3.client("sns", region_name="us-east-1")
    topic_arn = sns.create_topic(Name="finops-reports-test")["TopicArn"]
    monkeypatch.setenv("REPORT_TOPIC_ARN", topic_arn)
    monkeypatch.setenv("BEDROCK_MODEL_ID", "us.anthropic.claude-haiku-4-5-20251001-v1:0")
    return sns


def _seed_finding(ddb, sk_date="2026-07-01"):
    ddb.Table(TABLE_NAME).put_item(
        Item={
            "pk": "FINDING#IDLE_EC2",
            "sk": f"{sk_date}#i-abc123",
            "finding_type": "IDLE_EC2",
            "resource_id": "i-abc123",
            "estimated_monthly_savings": Decimal("7.59"),
        }
    )


def test_summary_published_with_week_of_data(ddb, report_env):
    _seed_finding(ddb)
    ddb.Table(TABLE_NAME).put_item(
        Item={
            "pk": "COST#2026-07-02",
            "sk": "SERVICE#AmazonEC2",
            "amount_usd": Decimal("4.2"),
        }
    )
    bedrock = FakeBedrock()

    result = summarizer.run(ddb_resource=ddb, bedrock_client=bedrock, today=TODAY)

    assert result == {"findings": 1, "cost_rows": 1, "published": True}
    prompt = bedrock.prompts[0]
    assert "i-abc123" in prompt
    assert "AmazonEC2" in prompt
    assert "TOP 3 SAVINGS ACTIONS" in prompt


def test_old_findings_excluded(ddb, report_env):
    _seed_finding(ddb, sk_date="2026-06-01")  # 32 days old — outside the week
    bedrock = FakeBedrock()

    result = summarizer.run(ddb_resource=ddb, bedrock_client=bedrock, today=TODAY)

    assert result["findings"] == 0
