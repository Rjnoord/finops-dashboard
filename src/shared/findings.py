"""Finding model + DynamoDB writer.

Single-table layout (on-demand billing):
  Findings:        pk = "FINDING#<type>"   sk = "<date>#<resource_id>"
  Cost aggregates: pk = "COST#<date>"      sk = "SERVICE#<service>"

The dashboard queries findings by type (newest first) and costs by day,
so the partition/sort keys mirror exactly those two access patterns.
"""

from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import Decimal

import boto3

from shared import config


@dataclass
class Finding:
    finding_type: str  # IDLE_EC2 | ORPHANED_STORAGE | TAG_COMPLIANCE
    resource_id: str
    region: str
    estimated_monthly_savings: float
    details: dict = field(default_factory=dict)

    def to_item(self) -> dict:
        now = datetime.now(timezone.utc)
        return {
            "pk": f"FINDING#{self.finding_type}",
            "sk": f"{now.date().isoformat()}#{self.resource_id}",
            "finding_type": self.finding_type,
            "resource_id": self.resource_id,
            "region": self.region,
            "estimated_monthly_savings": Decimal(str(round(self.estimated_monthly_savings, 2))),
            "details": _to_dynamo_safe(self.details),
            "detected_at": now.isoformat(),
        }


def _to_dynamo_safe(value):
    """DynamoDB rejects floats — convert them (recursively) to Decimal."""
    if isinstance(value, float):
        return Decimal(str(value))
    if isinstance(value, dict):
        return {k: _to_dynamo_safe(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_to_dynamo_safe(v) for v in value]
    return value


def write_findings(findings: list[Finding], ddb_resource=None) -> int:
    ddb = ddb_resource or boto3.resource("dynamodb")
    table = ddb.Table(config.table_name())
    with table.batch_writer() as batch:
        for finding in findings:
            batch.put_item(Item=finding.to_item())
    return len(findings)


def write_cost_rows(usage_date: str, costs_by_service: dict[str, float], ddb_resource=None) -> int:
    ddb = ddb_resource or boto3.resource("dynamodb")
    table = ddb.Table(config.table_name())
    with table.batch_writer() as batch:
        for service, amount in costs_by_service.items():
            batch.put_item(
                Item={
                    "pk": f"COST#{usage_date}",
                    "sk": f"SERVICE#{service}",
                    "usage_date": usage_date,
                    "service": service,
                    "amount_usd": Decimal(str(round(amount, 6))),
                }
            )
    return len(costs_by_service)
