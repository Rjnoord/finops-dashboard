import boto3

from collectors import orphaned_storage
from tests.conftest import scan_all


def test_unattached_volume_is_flagged(ddb):
    ec2 = boto3.client("ec2", region_name="us-east-1")
    volume = ec2.create_volume(AvailabilityZone="us-east-1a", Size=100)

    result = orphaned_storage.run(ec2_client=ec2, ddb_resource=ddb)

    assert result["findings"] == 1
    item = scan_all(ddb)[0]
    assert item["resource_id"] == volume["VolumeId"]
    assert item["details"]["kind"] == "unattached_ebs_volume"
    # 100 GB * $0.08
    assert float(item["estimated_monthly_savings"]) == 8.0


def test_attached_volume_is_not_flagged(ddb):
    ec2 = boto3.client("ec2", region_name="us-east-1")
    instance = ec2.run_instances(
        ImageId="ami-12345678", MinCount=1, MaxCount=1, InstanceType="t3.micro"
    )["Instances"][0]
    volume = ec2.create_volume(AvailabilityZone="us-east-1a", Size=50)
    ec2.attach_volume(
        InstanceId=instance["InstanceId"], VolumeId=volume["VolumeId"], Device="/dev/sdf"
    )

    result = orphaned_storage.run(ec2_client=ec2, ddb_resource=ddb)

    flagged = [i for i in scan_all(ddb) if i["resource_id"] == volume["VolumeId"]]
    assert flagged == []
    assert result["findings"] == 0


def test_unassociated_eip_is_flagged(ddb):
    ec2 = boto3.client("ec2", region_name="us-east-1")
    allocation = ec2.allocate_address(Domain="vpc")

    result = orphaned_storage.run(ec2_client=ec2, ddb_resource=ddb)

    assert result["findings"] == 1
    item = scan_all(ddb)[0]
    assert item["resource_id"] == allocation["AllocationId"]
    assert item["details"]["kind"] == "unassociated_elastic_ip"
    assert float(item["estimated_monthly_savings"]) == 3.6


def test_recent_snapshot_is_not_flagged(ddb):
    ec2 = boto3.client("ec2", region_name="us-east-1")
    volume = ec2.create_volume(AvailabilityZone="us-east-1a", Size=10)
    ec2.create_snapshot(VolumeId=volume["VolumeId"])  # brand new — inside age threshold

    orphaned_storage.run(ec2_client=ec2, ddb_resource=ddb)

    kinds = [i["details"]["kind"] for i in scan_all(ddb)]
    assert "stale_snapshot" not in kinds
