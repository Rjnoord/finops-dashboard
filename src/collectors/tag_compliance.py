"""Tag compliance auditor.

Walks every resource the Resource Groups Tagging API can see, checks the
required tag set, and writes one summary finding with the compliance
percentage plus a sample of the worst offenders.

Known limitation (worth saying in an interview): the Tagging API only
surfaces resources that have — or once had — at least one tag; fully
untagged resources in some services never appear. AWS Config is the
complete-inventory upgrade path.
"""

import boto3

from shared import config, logger
from shared.findings import Finding, write_findings

MAX_OFFENDERS_IN_DETAILS = 25


def _all_resources(tagging) -> list[dict]:
    resources = []
    paginator = tagging.get_paginator("get_resources")
    for page in paginator.paginate():
        resources.extend(page["ResourceTagMappingList"])
    return resources


def run(tagging_client=None, ddb_resource=None) -> dict:
    tagging = tagging_client or boto3.client("resourcegroupstaggingapi")
    region = tagging.meta.region_name
    required = set(config.required_tags())

    resources = _all_resources(tagging)
    noncompliant = []
    for resource in resources:
        tag_keys = {tag["Key"] for tag in resource.get("Tags", [])}
        missing = required - tag_keys
        if missing:
            noncompliant.append({"arn": resource["ResourceARN"], "missing_tags": sorted(missing)})

    total = len(resources)
    compliant = total - len(noncompliant)
    compliance_pct = round(100.0 * compliant / total, 1) if total else 100.0

    finding = Finding(
        finding_type="TAG_COMPLIANCE",
        resource_id="account-summary",
        region=region,
        estimated_monthly_savings=0.0,  # accountability finding, not a savings one
        details={
            "required_tags": sorted(required),
            "resources_checked": total,
            "compliant": compliant,
            "noncompliant": len(noncompliant),
            "compliance_pct": compliance_pct,
            "worst_offenders": noncompliant[:MAX_OFFENDERS_IN_DETAILS],
        },
    )
    write_findings([finding], ddb_resource)
    logger.info(
        "tag_compliance collector finished",
        resources_checked=total,
        compliance_pct=compliance_pct,
    )
    return {"resources_checked": total, "compliance_pct": compliance_pct}


def lambda_handler(event, context):
    return run()
