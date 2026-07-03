"""Orphaned storage detector.

Three classes of pure waste:
  - EBS volumes in 'available' state (attached to nothing, still billed)
  - Snapshots older than the age threshold that no registered AMI references
  - Elastic IPs not associated with anything (AWS charges for the idle ones)
"""

from datetime import datetime, timedelta, timezone

import boto3

from shared import config, logger
from shared.findings import Finding, write_findings

GP_VOLUME_PRICE_PER_GB_MONTH = 0.08
SNAPSHOT_PRICE_PER_GB_MONTH = 0.05
IDLE_EIP_PRICE_PER_MONTH = 3.60


def _unattached_volumes(ec2, region: str) -> list[Finding]:
    findings = []
    paginator = ec2.get_paginator("describe_volumes")
    for page in paginator.paginate(Filters=[{"Name": "status", "Values": ["available"]}]):
        for volume in page["Volumes"]:
            size_gb = volume["Size"]
            findings.append(
                Finding(
                    finding_type="ORPHANED_STORAGE",
                    resource_id=volume["VolumeId"],
                    region=region,
                    estimated_monthly_savings=size_gb * GP_VOLUME_PRICE_PER_GB_MONTH,
                    details={
                        "kind": "unattached_ebs_volume",
                        "size_gb": size_gb,
                        "volume_type": volume.get("VolumeType", "unknown"),
                        "recommendation": "Snapshot if data matters, then delete",
                    },
                )
            )
    return findings


def _stale_snapshots(ec2, region: str) -> list[Finding]:
    ami_snapshot_ids = set()
    for image in ec2.describe_images(Owners=["self"])["Images"]:
        for mapping in image.get("BlockDeviceMappings", []):
            snapshot_id = mapping.get("Ebs", {}).get("SnapshotId")
            if snapshot_id:
                ami_snapshot_ids.add(snapshot_id)

    cutoff = datetime.now(timezone.utc) - timedelta(days=config.snapshot_age_days())
    findings = []
    paginator = ec2.get_paginator("describe_snapshots")
    for page in paginator.paginate(OwnerIds=["self"]):
        for snapshot in page["Snapshots"]:
            if snapshot["SnapshotId"] in ami_snapshot_ids:
                continue
            if snapshot["StartTime"] >= cutoff:
                continue
            size_gb = snapshot["VolumeSize"]
            findings.append(
                Finding(
                    finding_type="ORPHANED_STORAGE",
                    resource_id=snapshot["SnapshotId"],
                    region=region,
                    estimated_monthly_savings=size_gb * SNAPSHOT_PRICE_PER_GB_MONTH,
                    details={
                        "kind": "stale_snapshot",
                        "size_gb": size_gb,
                        "started": snapshot["StartTime"].isoformat(),
                        "recommendation": "Delete if not required for compliance",
                    },
                )
            )
    return findings


def _idle_elastic_ips(ec2, region: str) -> list[Finding]:
    findings = []
    for address in ec2.describe_addresses()["Addresses"]:
        if "AssociationId" in address:
            continue
        findings.append(
            Finding(
                finding_type="ORPHANED_STORAGE",
                resource_id=address.get("AllocationId", address.get("PublicIp", "unknown")),
                region=region,
                estimated_monthly_savings=IDLE_EIP_PRICE_PER_MONTH,
                details={
                    "kind": "unassociated_elastic_ip",
                    "public_ip": address.get("PublicIp", ""),
                    "recommendation": "Release the address",
                },
            )
        )
    return findings


def run(ec2_client=None, ddb_resource=None) -> dict:
    ec2 = ec2_client or boto3.client("ec2")
    region = ec2.meta.region_name

    findings = (
        _unattached_volumes(ec2, region)
        + _stale_snapshots(ec2, region)
        + _idle_elastic_ips(ec2, region)
    )
    written = write_findings(findings, ddb_resource)
    total = round(sum(f.estimated_monthly_savings for f in findings), 2)
    logger.info(
        "orphaned_storage collector finished",
        findings=written,
        estimated_monthly_savings=total,
    )
    return {"findings": written, "estimated_monthly_savings": total}


def lambda_handler(event, context):
    return run()
