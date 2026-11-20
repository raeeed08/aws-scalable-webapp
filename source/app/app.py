"""
Demo web app for the scalable architecture.

Every page shows WHICH instance and WHICH Availability Zone answered, so refreshing the page shows the load
balancer at work, and a counter stored in RDS shows that all instances share one database.

/health    load balancer health check (no database call, on purpose)
/          HTML page: instance, AZ, visit counter from PostgreSQL
/api/info  the same as JSON
/api/db    database version and failover check
/api/load  burns CPU for a moment, to demonstrate Auto Scaling
"""
import json
import os
import time
import urllib.request

import boto3
import psycopg
from flask import Flask, jsonify, render_template_string

app = Flask(__name__)
REGION = os.environ.get("AWS_REGION", "eu-west-3")
DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_NAME = os.environ.get("DB_NAME", "appdb")
SECRET_ARN = os.environ.get("DB_SECRET_ARN", "")
_secret = {"value": None, "at": 0.0}


def imds(path: str) -> str:
    """Instance metadata through IMDSv2 (token first; IMDSv1 is disabled in the launch template)."""
    try:
        req = urllib.request.Request("http://169.254.169.254/latest/api/token", method="PUT",
                                     headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"})
        token = urllib.request.urlopen(req, timeout=1).read().decode()
        req = urllib.request.Request(f"http://169.254.169.254/latest/meta-data/{path}",
                                     headers={"X-aws-ec2-metadata-token": token})
        return urllib.request.urlopen(req, timeout=1).read().decode()
    except OSError:
        return "local"


INSTANCE_ID = imds("instance-id")
AZ = imds("placement/availability-zone")


def credentials(refresh: bool = False) -> dict:
    """Read the RDS-managed secret; cached 5 minutes, re-read after a rotation."""
    if refresh or not _secret["value"] or time.time() - _secret["at"] > 300:
        sm = boto3.client("secretsmanager", region_name=REGION)
        _secret["value"] = json.loads(sm.get_secret_value(SecretId=SECRET_ARN)["SecretString"])
        _secret["at"] = time.time()
    return _secret["value"]


def connect():
    for attempt in (1, 2):
        c = credentials(refresh=attempt == 2)
        try:
            return psycopg.connect(host=DB_HOST, dbname=DB_NAME, user=c["username"], password=c["password"],
                                   connect_timeout=3, sslmode="require")
        except psycopg.OperationalError as exc:
            if attempt == 2 or "password" not in str(exc):
                raise


def record_visit() -> int:
    with connect() as conn, conn.cursor() as cur:
        cur.execute("CREATE TABLE IF NOT EXISTS visits (id bigserial PRIMARY KEY, instance text, az text, at timestamptz DEFAULT now())")
        cur.execute("INSERT INTO visits (instance, az) VALUES (%s, %s)", (INSTANCE_ID, AZ))
        cur.execute("SELECT count(*) FROM visits")
        return cur.fetchone()[0]


PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Scalable Web App</title>
<link rel="stylesheet" href="/static/style.css"></head><body><main>
<img src="/static/logo.svg" alt="" width="56" height="56">
<h1>Scalable web application on AWS</h1>
<p class="lead">Refresh the page: the load balancer sends you to different instances in different Availability Zones.</p>
<dl>
<dt>Instance</dt><dd>{{ instance }}</dd>
<dt>Availability Zone</dt><dd>{{ az }}</dd>
<dt>Visits (stored in RDS Multi-AZ)</dt><dd>{{ visits }}</dd>
<dt>Environment</dt><dd>{{ env }}</dd>
</dl>
<p class="small">CloudFront → WAF → Application Load Balancer → Auto Scaling group (EC2, private subnets) → RDS PostgreSQL Multi-AZ.
Static files come from S3 through CloudFront.</p>
</main></body></html>"""


@app.get("/health")
def health():
    return "ok", 200


@app.get("/")
def index():
    try:
        visits = record_visit()
    except Exception as exc:  # the page stays up and says why
        app.logger.warning("database unavailable: %s", exc)
        visits = "database unavailable"
    return render_template_string(PAGE, instance=INSTANCE_ID, az=AZ, visits=visits, env=os.environ.get("APP_ENV", "dev"))


@app.get("/api/info")
def info():
    return jsonify(instance=INSTANCE_ID, az=AZ, time=time.time())


@app.get("/api/db")
def db():
    t0 = time.perf_counter()
    try:
        with connect() as conn, conn.cursor() as cur:
            cur.execute("SELECT version(), inet_server_addr()::text")
            version, server = cur.fetchone()
        return jsonify(ok=True, version=version, server_ip=server, ms=round((time.perf_counter() - t0) * 1000, 1), instance=INSTANCE_ID)
    except Exception as exc:
        return jsonify(ok=False, error=type(exc).__name__, instance=INSTANCE_ID), 503


@app.get("/api/load")
def load():
    """About 0.5 s of CPU work: call it in a loop to push the CPU over the scaling target."""
    end = time.perf_counter() + 0.5
    n = 0
    while time.perf_counter() < end:
        n += sum(i * i for i in range(1000))
    return jsonify(instance=INSTANCE_ID, az=AZ, work=n)
