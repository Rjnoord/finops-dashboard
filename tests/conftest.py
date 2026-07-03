import os

import boto3
import pytest
from moto import mock_aws

TABLE_NAME = "finops-data-test"


@pytest.fixture(autouse=True)
def aws_env(monkeypatch):
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SECURITY_TOKEN", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", "us-east-1")
    monkeypatch.setenv("TABLE_NAME", TABLE_NAME)
    monkeypatch.setenv("REQUIRED_TAGS", "Owner,Environment,CostCenter")
    monkeypatch.setenv("CPU_IDLE_THRESHOLD", "5.0")
    monkeypatch.setenv("LOOKBACK_DAYS", "7")
    monkeypatch.setenv("SNAPSHOT_AGE_DAYS", "90")


@pytest.fixture
def aws():
    with mock_aws():
        yield


@pytest.fixture
def ddb(aws):
    resource = boto3.resource("dynamodb", region_name="us-east-1")
    resource.create_table(
        TableName=TABLE_NAME,
        KeySchema=[
            {"AttributeName": "pk", "KeyType": "HASH"},
            {"AttributeName": "sk", "KeyType": "RANGE"},
        ],
        AttributeDefinitions=[
            {"AttributeName": "pk", "AttributeType": "S"},
            {"AttributeName": "sk", "AttributeType": "S"},
        ],
        BillingMode="PAY_PER_REQUEST",
    )
    return resource


def scan_all(ddb_resource):
    return ddb_resource.Table(TABLE_NAME).scan()["Items"]


# Re-export for tests
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
