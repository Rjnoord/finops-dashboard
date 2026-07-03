from datetime import datetime, timedelta, timezone

import boto3

from collectors import idle_ec2
from tests.conftest import scan_all


def _launch_instance(ec2, instance_type="t3.micro"):
    response = ec2.run_instances(
        ImageId="ami-12345678", MinCount=1, MaxCount=1, InstanceType=instance_type
    )
    return response["Instances"][0]["InstanceId"]


def _put_cpu(cloudwatch, instance_id, percent):
    now = datetime.now(timezone.utc)
    cloudwatch.put_metric_data(
        Namespace="AWS/EC2",
        MetricData=[
            {
                "MetricName": "CPUUtilization",
                "Dimensions": [{"Name": "InstanceId", "Value": instance_id}],
                "Timestamp": now - timedelta(days=1),
                "Value": percent,
                "Unit": "Percent",
            }
        ],
    )


def test_idle_instance_is_flagged_with_savings(ddb):
    ec2 = boto3.client("ec2", region_name="us-east-1")
    cloudwatch = boto3.client("cloudwatch", region_name="us-east-1")
    idle_id = _launch_instance(ec2, "t3.micro")
    _put_cpu(cloudwatch, idle_id, 1.5)

    result = idle_ec2.run(ec2_client=ec2, cloudwatch_client=cloudwatch, ddb_resource=ddb)

    assert result["findings"] == 1
    items = scan_all(ddb)
    assert len(items) == 1
    item = items[0]
    assert item["pk"] == "FINDING#IDLE_EC2"
    assert item["resource_id"] == idle_id
    # t3.micro: 0.0104/hr * 730 = 7.59
    assert float(item["estimated_monthly_savings"]) == 7.59
    assert float(item["details"]["avg_cpu_percent"]) == 1.5


def test_busy_instance_is_not_flagged(ddb):
    ec2 = boto3.client("ec2", region_name="us-east-1")
    cloudwatch = boto3.client("cloudwatch", region_name="us-east-1")
    busy_id = _launch_instance(ec2)
    _put_cpu(cloudwatch, busy_id, 62.0)

    result = idle_ec2.run(ec2_client=ec2, cloudwatch_client=cloudwatch, ddb_resource=ddb)

    assert result["findings"] == 0
    assert scan_all(ddb) == []


def test_instance_without_metrics_is_skipped(ddb):
    ec2 = boto3.client("ec2", region_name="us-east-1")
    cloudwatch = boto3.client("cloudwatch", region_name="us-east-1")
    _launch_instance(ec2)  # no CPU datapoints at all

    result = idle_ec2.run(ec2_client=ec2, cloudwatch_client=cloudwatch, ddb_resource=ddb)

    assert result["instances_checked"] == 1
    assert result["findings"] == 0
