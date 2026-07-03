"""Daily cost aggregator.

Pulls yesterday's spend by service from the Cost Explorer API and stores it
in DynamoDB, so the dashboard reads a cheap key lookup instead of calling
Cost Explorer ($0.01 per request) on every page load.
"""

from datetime import date, timedelta

import boto3

from shared import logger
from shared.findings import write_cost_rows


def run(ce_client=None, ddb_resource=None, target_date: date | None = None) -> dict:
    ce = ce_client or boto3.client("ce")
    usage_date = target_date or (date.today() - timedelta(days=1))
    start = usage_date.isoformat()
    end = (usage_date + timedelta(days=1)).isoformat()

    response = ce.get_cost_and_usage(
        TimePeriod={"Start": start, "End": end},
        Granularity="DAILY",
        Metrics=["UnblendedCost"],
        GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
    )

    costs_by_service: dict[str, float] = {}
    for result in response["ResultsByTime"]:
        for group in result["Groups"]:
            service = group["Keys"][0]
            amount = float(group["Metrics"]["UnblendedCost"]["Amount"])
            if amount > 0:
                costs_by_service[service] = costs_by_service.get(service, 0.0) + amount

    written = write_cost_rows(start, costs_by_service, ddb_resource)
    total = round(sum(costs_by_service.values()), 4)
    logger.info(
        "cost_aggregator finished",
        usage_date=start,
        services=written,
        total_usd=total,
    )
    return {"usage_date": start, "services": written, "total_usd": total}


def lambda_handler(event, context):
    return run()
