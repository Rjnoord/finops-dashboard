"""moto doesn't implement ce:GetCostAndUsage, so Cost Explorer is stubbed
with botocore's Stubber while DynamoDB stays a real moto mock."""

from datetime import date

import boto3
from botocore.stub import Stubber

from collectors import cost_aggregator
from tests.conftest import scan_all

TARGET = date(2026, 7, 2)


def _stubbed_ce(groups):
    ce = boto3.client("ce", region_name="us-east-1")
    stubber = Stubber(ce)
    stubber.add_response(
        "get_cost_and_usage",
        {
            "ResultsByTime": [
                {
                    "TimePeriod": {"Start": "2026-07-02", "End": "2026-07-03"},
                    "Groups": [
                        {
                            "Keys": [service],
                            "Metrics": {"UnblendedCost": {"Amount": str(amount), "Unit": "USD"}},
                        }
                        for service, amount in groups
                    ],
                    "Total": {},
                    "Estimated": False,
                }
            ]
        },
        {
            "TimePeriod": {"Start": "2026-07-02", "End": "2026-07-03"},
            "Granularity": "DAILY",
            "Metrics": ["UnblendedCost"],
            "GroupBy": [{"Type": "DIMENSION", "Key": "SERVICE"}],
        },
    )
    stubber.activate()
    return ce


def test_costs_written_per_service(ddb):
    ce = _stubbed_ce([("AmazonEC2", 4.20), ("AmazonS3", 0.87), ("AWSLambda", 0.0)])

    result = cost_aggregator.run(ce_client=ce, ddb_resource=ddb, target_date=TARGET)

    # zero-cost services are dropped
    assert result["services"] == 2
    assert result["total_usd"] == 5.07

    items = {i["sk"]: i for i in scan_all(ddb)}
    assert set(items) == {"SERVICE#AmazonEC2", "SERVICE#AmazonS3"}
    ec2_row = items["SERVICE#AmazonEC2"]
    assert ec2_row["pk"] == "COST#2026-07-02"
    assert float(ec2_row["amount_usd"]) == 4.20


def test_empty_day_writes_nothing(ddb):
    ce = _stubbed_ce([])

    result = cost_aggregator.run(ce_client=ce, ddb_resource=ddb, target_date=TARGET)

    assert result["services"] == 0
    assert scan_all(ddb) == []
