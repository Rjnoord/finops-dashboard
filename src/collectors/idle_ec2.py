"""Idle EC2 detector.

Flags running instances whose average CPU over the lookback window is below
the idle threshold, and estimates the monthly waste from a conservative
on-demand price map. Instances with no CPU datapoints (e.g. just launched)
are skipped — absence of data is not evidence of idleness.

Roadmap: replace the static price map with the AWS Pricing API and add
memory metrics via the CloudWatch agent for a true rightsizing signal.
"""

from datetime import datetime, timedelta, timezone

import boto3

from shared import config, logger
from shared.findings import Finding, write_findings

HOURS_PER_MONTH = 730

# Conservative us-east-1 on-demand hourly prices for common lab/dev types.
ON_DEMAND_HOURLY = {
    "t2.micro": 0.0116,
    "t3.micro": 0.0104,
    "t3.small": 0.0208,
    "t3.medium": 0.0416,
    "t3.large": 0.0832,
    "m5.large": 0.096,
    "m5.xlarge": 0.192,
    "c5.large": 0.085,
}
DEFAULT_HOURLY = 0.05


def _running_instances(ec2) -> list[dict]:
    instances = []
    paginator = ec2.get_paginator("describe_instances")
    for page in paginator.paginate(
        Filters=[{"Name": "instance-state-name", "Values": ["running"]}]
    ):
        for reservation in page["Reservations"]:
            instances.extend(reservation["Instances"])
    return instances


def _average_cpu(cloudwatch, instance_ids: list[str], days: int) -> dict[str, float]:
    """One GetMetricData call for up to 500 instances — cheaper and faster
    than a GetMetricStatistics call per instance."""
    if not instance_ids:
        return {}
    end = datetime.now(timezone.utc)
    start = end - timedelta(days=days)
    queries = [
        {
            "Id": f"cpu{i}",
            "MetricStat": {
                "Metric": {
                    "Namespace": "AWS/EC2",
                    "MetricName": "CPUUtilization",
                    "Dimensions": [{"Name": "InstanceId", "Value": instance_id}],
                },
                "Period": 86400,
                "Stat": "Average",
            },
        }
        for i, instance_id in enumerate(instance_ids)
    ]
    averages: dict[str, float] = {}
    response = cloudwatch.get_metric_data(MetricDataQueries=queries, StartTime=start, EndTime=end)
    for result in response["MetricDataResults"]:
        index = int(result["Id"].removeprefix("cpu"))
        values = result.get("Values", [])
        if values:
            averages[instance_ids[index]] = sum(values) / len(values)
    return averages


def run(ec2_client=None, cloudwatch_client=None, ddb_resource=None) -> dict:
    ec2 = ec2_client or boto3.client("ec2")
    cloudwatch = cloudwatch_client or boto3.client("cloudwatch")
    region = ec2.meta.region_name
    threshold = config.cpu_idle_threshold()
    days = config.lookback_days()

    instances = _running_instances(ec2)
    by_id = {i["InstanceId"]: i for i in instances}
    averages = _average_cpu(cloudwatch, list(by_id), days)

    findings = []
    for instance_id, avg_cpu in averages.items():
        if avg_cpu >= threshold:
            continue
        instance_type = by_id[instance_id]["InstanceType"]
        monthly_cost = ON_DEMAND_HOURLY.get(instance_type, DEFAULT_HOURLY) * HOURS_PER_MONTH
        findings.append(
            Finding(
                finding_type="IDLE_EC2",
                resource_id=instance_id,
                region=region,
                estimated_monthly_savings=monthly_cost,
                details={
                    "instance_type": instance_type,
                    "avg_cpu_percent": round(avg_cpu, 2),
                    "lookback_days": days,
                    "recommendation": "Stop or downsize; consider scheduling if dev/test",
                },
            )
        )

    written = write_findings(findings, ddb_resource)
    logger.info(
        "idle_ec2 collector finished",
        instances_checked=len(instances),
        findings=written,
    )
    return {"instances_checked": len(instances), "findings": written}


def lambda_handler(event, context):
    return run()
