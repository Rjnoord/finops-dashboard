import boto3

from collectors import tag_compliance
from tests.conftest import scan_all


def _make_bucket(name, tags=None):
    s3 = boto3.client("s3", region_name="us-east-1")
    s3.create_bucket(Bucket=name)
    if tags:
        s3.put_bucket_tagging(
            Bucket=name,
            Tagging={"TagSet": [{"Key": k, "Value": v} for k, v in tags.items()]},
        )


def test_compliance_percentage_and_offenders(ddb):
    _make_bucket(
        "compliant-bucket",
        {"Owner": "rj", "Environment": "dev", "CostCenter": "eng"},
    )
    _make_bucket("partial-bucket", {"Owner": "rj"})

    tagging = boto3.client("resourcegroupstaggingapi", region_name="us-east-1")
    result = tag_compliance.run(tagging_client=tagging, ddb_resource=ddb)

    assert result["resources_checked"] == 2
    assert result["compliance_pct"] == 50.0

    item = scan_all(ddb)[0]
    assert item["pk"] == "FINDING#TAG_COMPLIANCE"
    details = item["details"]
    assert int(details["noncompliant"]) == 1
    offender = details["worst_offenders"][0]
    assert "partial-bucket" in offender["arn"]
    assert offender["missing_tags"] == ["CostCenter", "Environment"]


def test_no_resources_reports_full_compliance(ddb):
    tagging = boto3.client("resourcegroupstaggingapi", region_name="us-east-1")
    result = tag_compliance.run(tagging_client=tagging, ddb_resource=ddb)

    assert result["resources_checked"] == 0
    assert result["compliance_pct"] == 100.0
