"""FinOps dashboard — Streamlit.

Reads the DynamoDB findings/cost table the collectors populate, plus the Cost
Explorer anomalies API. Read-only: nothing here writes to AWS.

Run locally:
    pip install -r dashboard/requirements.txt
    streamlit run dashboard/app.py
"""

from datetime import date, datetime, timedelta
from decimal import Decimal

import altair as alt
import boto3
import pandas as pd
import streamlit as st
from boto3.dynamodb.conditions import Key

TABLE_NAME = "finops-data"
FINDING_TYPES = ["IDLE_EC2", "ORPHANED_STORAGE", "TAG_COMPLIANCE"]

# Chart ink — single sequential hue for magnitude, per the dataviz method.
BLUE = "#2a78d6"
GRID = "#e1e0d9"
MUTED = "#898781"

st.set_page_config(page_title="FinOps Dashboard", page_icon="📉", layout="wide")


@st.cache_data(ttl=300)
def load_costs(days: int) -> pd.DataFrame:
    table = boto3.resource("dynamodb").Table(TABLE_NAME)
    rows = []
    for offset in range(days):
        day = (date.today() - timedelta(days=offset + 1)).isoformat()
        response = table.query(KeyConditionExpression=Key("pk").eq(f"COST#{day}"))
        rows.extend(response["Items"])
    if not rows:
        return pd.DataFrame(columns=["usage_date", "service", "amount_usd"])
    df = pd.DataFrame(rows)
    df["amount_usd"] = df["amount_usd"].astype(float)
    return df[["usage_date", "service", "amount_usd"]]


@st.cache_data(ttl=300)
def load_findings(days: int) -> pd.DataFrame:
    table = boto3.resource("dynamodb").Table(TABLE_NAME)
    since = (date.today() - timedelta(days=days)).isoformat()
    rows = []
    for finding_type in FINDING_TYPES:
        response = table.query(
            KeyConditionExpression=Key("pk").eq(f"FINDING#{finding_type}") & Key("sk").gte(since)
        )
        rows.extend(response["Items"])
    if not rows:
        return pd.DataFrame()
    df = pd.DataFrame(rows)
    df["estimated_monthly_savings"] = df["estimated_monthly_savings"].astype(float)
    return df


@st.cache_data(ttl=300)
def load_anomalies(days: int) -> pd.DataFrame:
    ce = boto3.client("ce")
    start = (date.today() - timedelta(days=days)).isoformat()
    response = ce.get_anomalies(
        DateInterval={"StartDate": start, "EndDate": date.today().isoformat()}
    )
    rows = [
        {
            "detected": anomaly["AnomalyStartDate"][:10],
            "service": anomaly.get("RootCauses", [{}])[0].get("Service", "unknown"),
            "impact_usd": float(anomaly["Impact"]["TotalImpact"]),
        }
        for anomaly in response.get("Anomalies", [])
    ]
    return pd.DataFrame(rows)


def latest_compliance(findings: pd.DataFrame) -> dict | None:
    if findings.empty:
        return None
    compliance = findings[findings["finding_type"] == "TAG_COMPLIANCE"]
    if compliance.empty:
        return None
    details = compliance.sort_values("sk").iloc[-1]["details"]
    return {k: (float(v) if isinstance(v, Decimal) else v) for k, v in details.items()}


def spend_trend_chart(costs: pd.DataFrame) -> alt.Chart:
    daily = costs.groupby("usage_date", as_index=False)["amount_usd"].sum()
    daily["usage_date"] = pd.to_datetime(daily["usage_date"])
    return (
        alt.Chart(daily)
        .mark_area(
            line={"color": BLUE, "strokeWidth": 2},
            color=alt.Gradient(
                gradient="linear",
                stops=[
                    alt.GradientStop(color="#cde2fb", offset=0),
                    alt.GradientStop(color="#9ec5f4", offset=1),
                ],
                x1=1,
                x2=1,
                y1=1,
                y2=0,
            ),
        )
        .encode(
            x=alt.X("usage_date:T", title=None, axis=alt.Axis(grid=False, labelColor=MUTED)),
            y=alt.Y(
                "amount_usd:Q",
                title="USD / day",
                axis=alt.Axis(gridColor=GRID, labelColor=MUTED, format="$.2f"),
            ),
            tooltip=[
                alt.Tooltip("usage_date:T", title="Date"),
                alt.Tooltip("amount_usd:Q", title="Spend", format="$.2f"),
            ],
        )
        .properties(height=260)
    )


def service_breakdown_chart(costs: pd.DataFrame) -> alt.Chart:
    by_service = (
        costs.groupby("service", as_index=False)["amount_usd"]
        .sum()
        .sort_values("amount_usd", ascending=False)
        .head(10)
    )
    return (
        alt.Chart(by_service)
        .mark_bar(color=BLUE, cornerRadiusEnd=4, height=18)
        .encode(
            x=alt.X(
                "amount_usd:Q",
                title="USD",
                axis=alt.Axis(gridColor=GRID, labelColor=MUTED, format="$.2f"),
            ),
            y=alt.Y("service:N", sort="-x", title=None, axis=alt.Axis(labelColor=MUTED)),
            tooltip=[
                alt.Tooltip("service:N", title="Service"),
                alt.Tooltip("amount_usd:Q", title="Spend", format="$.2f"),
            ],
        )
        .properties(height=260)
    )


def main() -> None:
    st.title("FinOps Cost Dashboard")
    st.caption(f"Account 448842988605 · data as of {datetime.now():%Y-%m-%d %H:%M}")

    days = st.sidebar.radio("Window", [7, 30, 90], index=1, format_func=lambda d: f"Last {d} days")

    costs = load_costs(days)
    findings = load_findings(days)
    compliance = latest_compliance(findings)

    waste = (
        findings[findings["finding_type"] != "TAG_COMPLIANCE"]
        if not findings.empty
        else pd.DataFrame()
    )

    # ---- KPI row ----
    k1, k2, k3, k4 = st.columns(4)
    total_spend = costs["amount_usd"].sum() if not costs.empty else 0.0
    k1.metric(f"Spend (last {days}d)", f"${total_spend:,.2f}")
    savings = waste["estimated_monthly_savings"].sum() if not waste.empty else 0.0
    k2.metric("Identified savings / mo", f"${savings:,.2f}")
    k3.metric(
        "Tag compliance",
        f"{compliance['compliance_pct']:.0f}%" if compliance else "—",
        help="Resources carrying all required tags (Owner, Environment, CostCenter)",
    )
    k4.metric("Open findings", len(waste) if not waste.empty else 0)

    st.divider()

    # ---- Charts ----
    c1, c2 = st.columns(2)
    with c1:
        st.subheader("Daily spend trend")
        if costs.empty:
            st.info("No cost rows yet — the cost aggregator runs daily at 08:30 UTC.")
        else:
            st.altair_chart(spend_trend_chart(costs), use_container_width=True)
    with c2:
        st.subheader("Spend by service")
        if costs.empty:
            st.info("No cost rows yet.")
        else:
            st.altair_chart(service_breakdown_chart(costs), use_container_width=True)

    # ---- Findings table ----
    st.subheader("Savings opportunities")
    if waste.empty:
        st.info(
            "No waste findings — either the collectors haven't run yet, or the account is clean."
        )
    else:
        table = waste[["finding_type", "resource_id", "region", "estimated_monthly_savings"]].copy()
        table = table.sort_values("estimated_monthly_savings", ascending=False)
        st.dataframe(
            table,
            use_container_width=True,
            hide_index=True,
            column_config={
                "finding_type": "Type",
                "resource_id": "Resource",
                "region": "Region",
                "estimated_monthly_savings": st.column_config.NumberColumn(
                    "Est. savings / mo", format="$%.2f"
                ),
            },
        )

    # ---- Tag compliance detail ----
    if compliance:
        st.subheader("Tag compliance")
        st.progress(
            min(compliance["compliance_pct"] / 100, 1.0),
            text=(
                f"{compliance['compliant']:.0f} of {compliance['resources_checked']:.0f} "
                f"resources carry all required tags"
            ),
        )
        offenders = compliance.get("worst_offenders", [])
        if offenders:
            with st.expander(f"Worst offenders ({len(offenders)})"):
                st.dataframe(pd.DataFrame(offenders), use_container_width=True, hide_index=True)

    # ---- Anomalies ----
    st.subheader("Cost anomalies")
    try:
        anomalies = load_anomalies(min(days, 90))
    except Exception as error:  # noqa: BLE001 — surface, don't crash the page
        st.warning(f"Could not load anomalies: {error}")
        anomalies = pd.DataFrame()
    if anomalies.empty:
        st.info("No anomalies detected in this window.")
    else:
        st.dataframe(
            anomalies.sort_values("detected", ascending=False),
            use_container_width=True,
            hide_index=True,
            column_config={
                "detected": "Detected",
                "service": "Service",
                "impact_usd": st.column_config.NumberColumn("Impact", format="$%.2f"),
            },
        )


if __name__ == "__main__":
    main()
