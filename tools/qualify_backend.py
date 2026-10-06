"""Disposable backend qualification. Never uses an installed deployment.

Run one layout per invocation; unique projects/anonymous volumes are cleaned
in finally. --existing is restricted to explicitly named test deployments.
"""
import argparse
import base64
import csv
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.request
import uuid
import yaml
from reconcile_telemetry import reconcile

ROOT = Path(__file__).resolve().parents[1]

def run(command, data=None):
    result = subprocess.run(command, input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, cwd=ROOT)
    if result.returncode:
        raise RuntimeError("Command failed: " + " ".join(command[:4]) + "\n"
                           + result.stdout.decode(errors="replace")[-2500:]
                           + result.stderr.decode(errors="replace")[-2500:])
    return result.stdout.decode()

def wait_for(check, description, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if check():
                return
        except (RuntimeError, OSError, ValueError):
            pass
        time.sleep(1)
    raise RuntimeError("Timed out: " + description)

class Stack:
    def __init__(self, args, scratch):
        self.args = args
        self.name = args.name or "ect-v2-" + uuid.uuid4().hex[:8] + "-test"
        if not self.name.startswith("ect-") or not self.name.endswith("-test"):
            raise ValueError("Qualification targets must be named ect-...-test")
        self.env = {"POSTGRES_DB": "v2custom", "POSTGRES_USER": "v2owner",
                    "POSTGRES_PASSWORD": "v2test", "TELEGRAF_PASSWORD": "ingesttest",
                    "GRAFANA_READER_PASSWORD": "readertest"}
        os.environ.update(self.env)
        self.compose = ["docker", "compose", "-p", self.name, "-f",
                        str(ROOT / "ops/local-stack/docker-compose.yml")]
        if args.layout == "compose":
            override = args.override
            if not override:
                override = scratch / "override.yml"
                override.write_text(f"""services:
  timescaledb:
    ports: !override ["127.0.0.1::5432"]
    volumes: !override
      - test_db:/var/lib/postgresql/data
      - {ROOT.as_posix()}/db/schema.sql:/docker-entrypoint-initdb.d/01_schema.sql:ro
      - {ROOT.as_posix()}/ops/backend/init_roles.sh:/docker-entrypoint-initdb.d/02_roles.sh:ro
      - {ROOT.as_posix()}/db/scripts/bootstrap_roles.sql:/etc/ect/bootstrap_roles.sql:ro
      - {ROOT.as_posix()}/ops/backend:/ops/backend:ro
      - test_exports:/exports
  mosquitto:
    ports: !override ["127.0.0.1::1883"]
  csv-streamer:
    volumes: !override [test_exports:/exports]
  csv-server:
    ports: !override ["127.0.0.1::8080"]
    volumes: !override [test_exports:/exports:ro]
  grafana:
    ports: !override ["127.0.0.1::3000"]
volumes:
  test_db:
  test_exports:
""")
            self.compose += ["-f", str(Path(override).resolve())]

    def start(self):
        if not self.args.existing:
            if self.args.layout == "compose":
                run(self.compose + ["up", "-d", "--build"])
            else:
                run(["docker", "build", "-t", "ect-backend-v2-test",
                     "-f", "ops/backend/Dockerfile", "."])
                command = ["docker", "run", "-d", "--name", self.name,
                           "--label", "ect.disposable=true"]
                for port in (1883, 3000, 8080):
                    command += ["-p", f"127.0.0.1::{port}"]
                for key, value in self.env.items():
                    command += ["-e", key + "=" + value]
                run(command + ["ect-backend-v2-test"])
        wait_for(lambda: self.sql("SELECT version FROM schema_metadata") == "2",
                 "initialized v2 schema")
        import hashlib
        checksum = hashlib.sha256((ROOT / "db/schema.sql").read_bytes()).hexdigest()
        assert self.sql("SELECT schema_sha256 FROM schema_metadata") == checksum

    def command(self, service, command, data=None):
        base = (self.compose + ["exec", "-T", service] if self.args.layout == "compose"
                else ["docker", "exec", "-i", self.name])
        return run(base + command, data)

    def sql(self, sql, reader=False):
        if reader:
            sql = "SET ROLE grafana_reader; " + sql
        return self.command("timescaledb",
                            ["env", "PGPASSWORD=v2test", "psql", "-h", "127.0.0.1", "-U", "v2owner", "-d", "v2custom", "-qAt",
                             "-v", "ON_ERROR_STOP=1", "-c", sql]).strip()

    def publish(self, topic, payload):
        self.command("mosquitto", ["mosquitto_pub", "-h", "127.0.0.1", "-q", "1",
                                  "-t", "telemetry/eco_archers/" + topic, "-s"],
                     json.dumps(payload).encode())

    def port(self, service, port):
        if self.args.layout == "compose":
            return run(self.compose + ["port", service, str(port)]).strip()
        return run(["docker", "port", self.name, str(port)]).strip()

    def lifecycle(self, action, service):
        if self.args.layout == "compose":
            return run(self.compose + [action, service])
        supervisor_name = {"timescaledb": "postgres"}.get(service, service)
        return self.command(service, ["supervisorctl", "-c", "/etc/supervisord.conf",
                                      action, supervisor_name])

    def csv(self, uid):
        url = "http://" + self.port("csv-server", 8080) + "/events_v2_" + uid + ".csv"
        with urllib.request.urlopen(url, timeout=5) as response:
            return list(csv.DictReader(io.StringIO(response.read().decode())))

    def restart(self):
        if self.args.layout == "compose":
            run(self.compose + ["restart"])
        else:
            run(["docker", "restart", self.name])

    def close(self):
        if self.args.existing:
            return
        if self.args.layout == "compose":
            run(self.compose + ["down", "--volumes", "--remove-orphans"])
        else:
            run(["docker", "rm", "-f", "-v", self.name])

def queries():
    result = []
    for path in (ROOT / "ops/grafana/dashboards").glob("*.json"):
        dashboard = json.loads(path.read_text())
        for panel in dashboard["panels"]:
            for target in panel.get("targets", []):
                if target.get("rawSql"):
                    result.append((path.name + ":" + str(panel["id"]), target["rawSql"]))
        for variable in dashboard["templating"]["list"]:
            result.append((path.name + ":" + variable["name"], variable["query"]))
    rules = yaml.safe_load((ROOT / "ops/grafana/provisioning/alerting/rules.yml").read_text())
    for group in rules["groups"]:
        for rule in group["rules"]:
            for target in rule["data"]:
                if target["model"].get("rawSql"):
                    result.append((rule["uid"], target["model"]["rawSql"]))
    return result

def qualify_recovery_tools(stack, args, events):
    """Exercise the operator tools on this disposable stack, never a live target."""
    python = '/opt/csv-runtime/bin/python3' if args.layout == 'single' else 'python3'
    files = {name: (ROOT / name).read_text(encoding='utf-8') for name in [
        'tools/initialize_backend.py', 'db/schema.sql', 'db/scripts/bootstrap_roles.sql',
        'tools/reconcile_telemetry.py', 'tools/replay_csv.py', 'ops/backend/telemetry_contract.py']}
    installer = """import json,sys
from pathlib import Path
for name,content in json.load(sys.stdin).items():
    path=Path('/tmp/ect-tools')/name
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(content,encoding='utf-8')
"""
    for service, runtime in [('timescaledb', 'python3'), ('csv-streamer', python)]:
        stack.command(service, [runtime, '-c', installer], json.dumps(files).encode())
    stack.sql('CREATE DATABASE utility_fixture')
    pg = ['env', 'PGHOST=127.0.0.1', 'PGDATABASE=utility_fixture', 'PGUSER=v2owner',
          'PGPASSWORD=v2test', 'TELEGRAF_PASSWORD=ingesttest', 'GRAFANA_READER_PASSWORD=readertest']
    initialize = pg + ['python3', '/tmp/ect-tools/tools/initialize_backend.py']
    stack.command('timescaledb', initialize)
    try:
        stack.command('timescaledb', initialize)
    except RuntimeError:
        pass
    else:
        raise AssertionError('Fresh-only initializer adopted an existing schema')
    stack.command('timescaledb', pg + ['psql', '-qAt', '-v', 'ON_ERROR_STOP=1', '-c',
                  "SELECT 1 / count(*) FROM schema_metadata WHERE version=2 AND schema_sha256 <> 'uninitialized'"])
    export_script = '/usr/local/bin/export_snapshot.py' if args.layout == 'single' else '/ops/backend/export_snapshot.py'
    reader = ['env', 'PGHOST=127.0.0.1', 'PGDATABASE=v2custom', 'PGUSER=grafana_reader', 'PGPASSWORD=readertest']
    stack.command('timescaledb', reader + ['python3', export_script, '--output', '/tmp/ect-snapshots'])
    stack.command('timescaledb', ['python3', '-c',
                  "from pathlib import Path; p=Path('/tmp/ect-snapshots'); assert len(list(p.glob('*.csv')))==4 and not list(p.glob('*.tmp'))"])
    try:
        stack.command('timescaledb', reader + ['PGPORT=1', 'python3', export_script, '--output', '/tmp/ect-export-failure'])
    except RuntimeError:
        pass
    else:
        raise AssertionError('Exporter did not propagate connection failure')
    stack.command('timescaledb', ['python3', '-c',
                  "from pathlib import Path; assert not list(Path('/tmp/ect-export-failure').iterdir())"])
    uid = str(uuid.uuid4())
    expected = [dict(row, session_uid=uid) for row in events]
    stack.publish('events', {'schema_version': 2, 'events': expected[:1]})
    wait_for(lambda: stack.sql(f"SELECT count(*) FROM telemetry_samples WHERE session_uid='{uid}'") == '1', 'repair seed')
    sql_csv = stack.sql(f"COPY (SELECT * FROM telemetry_samples WHERE session_uid='{uid}') TO STDOUT WITH CSV HEADER")
    stream = io.StringIO()
    writer = csv.DictWriter(stream, fieldnames=expected[0].keys())
    writer.writeheader()
    writer.writerows(expected)
    repair_files = {'events.csv': stream.getvalue(), 'sql.csv': sql_csv}
    stack.command('csv-streamer', [python, '-c', installer], json.dumps(repair_files).encode())
    command = [python, '/tmp/ect-tools/tools/replay_csv.py', '/tmp/ect-tools/events.csv',
               '--session', uid, '--sql-snapshot', '/tmp/ect-tools/sql.csv']
    dry_run = json.loads(stack.command('csv-streamer', command))
    assert dry_run['mode'] == 'dry-run' and dry_run['records_to_replay'] == 1
    stack.command('csv-streamer', command + ['--publish', '--host',
                  'mosquitto' if args.layout == 'compose' else '127.0.0.1'])
    wait_for(lambda: stack.sql(f"SELECT count(*) FROM telemetry_samples WHERE session_uid='{uid}'") == '2', 'CSV repair to SQL')
    wait_for(lambda: len(stack.csv(uid)) >= 2, 'CSV repair to archive')
    rows = json.loads(stack.sql(f"SELECT json_agg(t) FROM (SELECT * FROM telemetry_samples WHERE session_uid='{uid}') t"))
    for result in [reconcile(expected, rows), reconcile(expected, stack.csv(uid))]:
        assert not result['missing'] and not result['unexpected'] and not result['conflicts'], result
    print('Fresh-only bootstrap, reader export/failure cleanup and original-identity CSV repair passed', flush=True)
    return {'fresh_initialize': 'passed', 'existing_schema_refused': 'passed',
            'reader_export': 'passed', 'failed_export_cleanup': 'passed',
            'dry_run_missing_records': 1, 'replay_sql_csv': 'passed',
            'comparison': 'identity and all immutable metric fields'}

def qualify(stack, args, scratch):
    fixture = json.loads((ROOT / "test/fixtures/telemetry_v2_events.json").read_text())
    uid = str(uuid.uuid4())
    events = fixture["events"]
    for event in events:
        event["session_uid"] = uid
    metadata = json.loads((ROOT / "test/fixtures/telemetry_v2_session.json").read_text())
    metadata["uid"] = uid
    def count():
        return int(stack.sql(f"SELECT count(*) FROM telemetry_samples WHERE session_uid='{uid}'"))
    # Probe BOTH subscriptions; first-boot process readiness is insufficient.
    def subscriptions_ready():
        stack.publish("events", fixture)
        stack.publish("sessions", metadata)
        return count() == 2 and stack.sql(f"SELECT count(*) FROM sessions WHERE uid='{uid}'") == "1" and len(stack.csv(uid)) >= 2
    wait_for(subscriptions_ready, "both SQL/CSV subscriptions")
    assert stack.sql(f"SELECT count(DISTINCT time)||'|'||count(DISTINCT lap_number) FROM telemetry_samples WHERE session_uid='{uid}'") == "2|2"
    stack.publish("events", fixture)
    time.sleep(2)
    assert count() == 2
    final_metadata = dict(metadata, metadata_revision=3, session_state="ENDED",
                          ended_at_utc="2026-10-06T01:00:10Z", laps_completed=1)
    stack.publish("sessions", final_metadata)
    stack.publish("sessions", metadata)
    wait_for(lambda: stack.sql(f"SELECT session_state||'|'||metadata_revision FROM sessions WHERE uid='{uid}'") == "ENDED|3",
             "out-of-order metadata revisions")
    bad = dict(events[0], seq_in_session=3, lap_number="not-an-integer")
    good = dict(events[0], seq_in_session=4, value=73)
    stack.publish("events", {"schema_version": 2, "events": [bad, good]})
    wait_for(lambda: count() == 3, "valid neighbor after malformed event")
    wait_for(lambda: int(stack.sql(f"SELECT count(*) FROM ingest_rejections WHERE payload->>'session_uid'='{uid}'")) >= 1,
             "malformed input quarantine")
    conflict = dict(events[0], value=99)
    stack.publish("events", {"schema_version": 2, "events": [conflict]})
    wait_for(lambda: int(stack.sql(f"SELECT count(*) FROM ingest_rejections WHERE payload->>'session_uid'='{uid}'")) >= 2,
             "conflicting duplicate quarantine")
    # Independent source age is stale despite recent ingestion.
    assert stack.sql(f"SELECT bool_or(is_fresh) FROM latest_signals WHERE session_uid='{uid}'") == "f"
    assert stack.sql("SELECT has_table_privilege('telegraf_ingest','telemetry_raw','INSERT')") == "f"
    print("Contract ordering, idempotency, quarantine and role boundary passed", flush=True)

    # Non-empty analytics: a resetting cumulative counter contributes its new value.
    analytic_uid = str(uuid.uuid4())
    analytic = []
    for index, value in enumerate([1000, 1100, 20, 35], start=1):
        row = dict(events[0], session_uid=analytic_uid, seq_in_session=index,
                   signal_name="Joules_780", value=value, unit="J", lap_number=1,
                   ts_session_ms=index * 1000, ts_wall_utc=f"2026-10-06T02:00:0{index}Z",
                   observed_at_utc=f"2026-10-06T02:00:0{index}Z")
        analytic.append(row)
    analytic.append(dict(analytic[-1], seq_in_session=5, signal_name="Lap_Completed",
                         sample_kind="diagnostic", value=1, ts_session_ms=5000))
    stack.publish("events", {"schema_version": 2, "events": analytic})
    wait_for(lambda: stack.sql(f"SELECT energy_j FROM session_totals WHERE session_uid='{analytic_uid}'") == "135",
             "reset-safe totals before metadata")
    assert stack.sql(f"SELECT count(*) FROM session_catalog WHERE uid='{analytic_uid}'") == "1"
    stack.publish("sessions", dict(metadata, uid=analytic_uid, started_at_utc="2026-10-06T02:00:00Z"))
    wait_for(lambda: stack.sql(f"SELECT duration_seconds FROM lap_bounds WHERE session_uid='{analytic_uid}'") == "5.0000000000000000",
             "explicit lap boundary")
    gps = []
    for seq in range(6,10):
        gps.append(dict(analytic[0],seq_in_session=seq,
                        signal_name="GPS_Latitude_Deg" if seq%2==0 else "GPS_Longitude_Deg",
                        value=14.55 if seq%2==0 else 120.99,source="external_gps",
                        source_sample_id="fixed-fix",unit="deg",lap_number=1 if seq<8 else 2,
                        sample_kind="observation" if seq<8 else "snapshot"))
    stack.publish("events", {"schema_version": 2, "events": gps})
    wait_for(lambda: stack.sql(f"SELECT lap_number FROM gps_fixes WHERE session_uid='{analytic_uid}'")=="1",
             "snapshots cannot move a GPS fix into a later lap")
    # Execute every query under the actual Grafana reader role and both lap selections.
    checks = ["SET ROLE grafana_reader;"]
    for label, sql in queries():
        for lap in ("1", "-1"):
            rendered = sql.replace("${session_id:sqlstring}", "'" + analytic_uid + "'").replace("${lap_number:sqlstring}", "'" + lap + "'").replace("$__interval", "1s")
            checks.append("SELECT '"+label+"';")
            checks.append(rendered)
    stack.command("timescaledb", ["psql","-U","v2owner","-d","v2custom","-qAt","-v","ON_ERROR_STOP=1"], "\n".join(checks).encode())
    grafana_url = "http://" + stack.port("grafana", 3000)
    headers = {"Authorization": "Basic " + base64.b64encode(b"admin:admin").decode(),
               "Content-Type": "application/json"}
    request = urllib.request.Request(grafana_url + "/api/datasources/uid/timescaledb/health", headers=headers)
    wait_for(lambda: json.loads(urllib.request.urlopen(request, timeout=5).read())["status"] == "OK",
             "Grafana bounded datasource")
    request = urllib.request.Request(grafana_url + "/api/ds/query", headers=headers,
        data=json.dumps({"queries": [{"refId": "A", "datasource": {"uid": "timescaledb", "type": "postgres"},
                        "format": "table", "rawSql": f"SELECT energy_j FROM session_totals WHERE session_uid='{analytic_uid}'"}],
                         "from": "0", "to": "1791331200000"}).encode())
    grafana = json.loads(urllib.request.urlopen(request, timeout=10).read())
    assert grafana["results"]["A"]["frames"][0]["data"]["values"][0] == [135]
    print(f"{len(queries())} Grafana SQL queries, real datasource and nonempty analytics passed", flush=True)

    phone_result = None
    if not args.skip_phone_process:
        phone_dir = scratch / "phone"
        os.environ["ECT_TEST_MQTT_PORT"] = stack.port("mosquitto", 1883).rsplit(":", 1)[1]
        os.environ["ECT_TEST_OUTPUT"] = str(phone_dir)
        flutter = ([args.dart, args.flutter_tool] if args.flutter_tool else ["flutter"])
        run(flutter + ["test", "--no-pub", "test/phone_server_integration_test.dart", "--reporter", "expanded"])
        expected = [r for r in json.loads((phone_dir / "expected.json").read_text()) if "signal_name" in r]
        phone_uid = expected[0]["session_uid"]
        wait_for(lambda: int(stack.sql(f"SELECT count(*) FROM telemetry_samples WHERE session_uid='{phone_uid}'")) == len(expected),
                 "Dart capture journal to SQL")
        wait_for(lambda: len(stack.csv(phone_uid)) >= len(expected), "Dart capture to server CSV")
        rows = json.loads(stack.sql(f"SELECT json_agg(t) FROM (SELECT * FROM telemetry_samples WHERE session_uid='{phone_uid}') t"))
        sql_reconciliation = reconcile(expected, rows)
        server_reconciliation = reconcile(expected, stack.csv(phone_uid))
        local_csv = list(phone_dir.rglob("events_v2_*.csv"))
        local_rows = []
        for path in local_csv:
            local_rows.extend(csv.DictReader(io.StringIO(path.read_text())))
        local_reconciliation = reconcile(expected, local_rows)
        for result in [sql_reconciliation, server_reconciliation, local_reconciliation]:
            assert not result["missing"] and not result["unexpected"] and not result["conflicts"], result
        phone_result = {"sql": sql_reconciliation, "server_csv": server_reconciliation,
                        "local_csv": local_reconciliation,
                        "sqlite_bytes": sum(p.stat().st_size for p in phone_dir.glob("phone.db*"))}
        print("Real Dart CAN/recorder/SQLite/MQTT reconciled with SQL and both CSV paths", flush=True)

    recovery_tools = qualify_recovery_tools(stack, args, events)
    throughput_uid = str(uuid.uuid4())
    throughput = [dict(events[0], session_uid=throughput_uid, seq_in_session=i+1,
                       value=i, ts_session_ms=i) for i in range(3200)]
    begin = time.monotonic()
    publisher = '''
import json,os,sys
import paho.mqtt.client as mqtt
events=json.load(sys.stdin)
client=mqtt.Client(mqtt.CallbackAPIVersion.VERSION2,client_id="ect-throughput")
client.connect(os.environ["MQTT_HOST"],int(os.environ["MQTT_PORT"]))
client.loop_start()
try:
    for offset in range(0,len(events),32):
        info=client.publish(os.environ["TOPIC_EVENTS"],json.dumps({"schema_version":2,"events":events[offset:offset+32]}),qos=1)
        info.wait_for_publish(timeout=10)
        assert info.is_published()
finally:
    client.disconnect()
    client.loop_stop()
'''
    python = "/opt/csv-runtime/bin/python3" if args.layout=="single" else "python3"
    stack.command("csv-streamer", [python,"-c",publisher], json.dumps(throughput).encode())
    publish_seconds = time.monotonic()-begin
    wait_for(lambda: int(stack.sql(f"SELECT count(*) FROM telemetry_samples WHERE session_uid='{throughput_uid}'")) == 3200,
             "throughput SQL", timeout=120)
    wait_for(lambda: len(stack.csv(throughput_uid)) == 3200, "throughput CSV")
    print(f"Throughput: 3200 records at {3200/publish_seconds:.1f} records/s", flush=True)
    # Finite outage tests deliberately stay under the Telegraf/broker budgets.
    outage_uid = str(uuid.uuid4())
    sequence = 0
    outage_events = []
    for service in ("timescaledb", "telegraf"):
        print(f"Starting {args.outage_seconds}s {service} outage", flush=True)
        stack.lifecycle("stop", service)
        for second in range(args.outage_seconds):
            sequence += 1
            row = dict(events[0], session_uid=outage_uid, seq_in_session=sequence,
                       value=sequence, ts_session_ms=sequence * 1000)
            outage_events.append(row)
            stack.publish("events", {"schema_version": 2, "events": [row]})
            time.sleep(1)
        wait_for(lambda: len(stack.csv(outage_uid)) >= sequence, "independent CSV during SQL outage")
        stack.lifecycle("start", service)
        wait_for(lambda: int(stack.sql(f"SELECT count(*) FROM telemetry_samples WHERE session_uid='{outage_uid}'")) == sequence,
                 "outage replay", timeout=120)
    stack.lifecycle("stop", "csv-streamer")
    sequence += 1
    row = dict(events[0], session_uid=outage_uid, seq_in_session=sequence, value=sequence)
    outage_events.append(row)
    stack.publish("events", {"schema_version": 2, "events": [row]})
    stack.lifecycle("start", "csv-streamer")
    wait_for(lambda: len(stack.csv(outage_uid)) >= sequence, "CSV subscriber restart")
    # A clean broker/layout restart preserves database, archive and subscription state.
    stack.restart()
    wait_for(lambda: stack.sql("SELECT version FROM schema_metadata") == "2", "layout restart")
    wait_for(lambda: len(stack.csv(outage_uid)) >= sequence, "archive survives restart")
    # Redelivery to compressed storage remains idempotent.
    stack.sql("SELECT compress_chunk(c, if_not_compressed=>true) FROM show_chunks('telemetry_raw') c")
    stack.publish("events", fixture)
    time.sleep(3)
    assert count() == 3
    rows = json.loads(stack.sql(f"SELECT json_agg(t) FROM (SELECT * FROM telemetry_samples WHERE session_uid='{outage_uid}') t"))
    result = reconcile(outage_events, rows)
    assert not result["missing"] and not result["conflicts"], result
    csv_result = reconcile(outage_events, stack.csv(outage_uid))
    assert not csv_result["missing"] and not csv_result["conflicts"], csv_result
    return {"layout": args.layout, "schema_version": 2, "queries_executed": len(queries()),
            "outage_seconds_each": args.outage_seconds, "outage_records": sequence,
            "phone_process": phone_result, "hardware_qualification": "pending", "recovery_tools": recovery_tools,
            "outage_sql": result, "outage_csv": csv_result, "throughput_records": 3200,
            "publish_records_per_second": 3200/publish_seconds,
            "pending_json_bytes_per_event": len(json.dumps(events[0]).encode())}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--layout", choices=["compose", "single"], required=True)
    parser.add_argument("--name")
    parser.add_argument("--existing", action="store_true")
    parser.add_argument("--override", type=Path)
    parser.add_argument("--outage-seconds", type=int, default=60)
    parser.add_argument("--skip-phone-process", action="store_true")
    parser.add_argument("--dart")
    parser.add_argument("--flutter-tool")
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--keep-on-failure", action="store_true", help="Keep only this disposable target for diagnosis")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="ect-qualification-") as directory:
        scratch = Path(directory)
        stack = Stack(args, scratch)
        failed = False
        try:
            stack.start()
            report = qualify(stack, args, scratch)
            import hashlib
            report["schema_sha256"] = hashlib.sha256((ROOT / "db/schema.sql").read_bytes().replace(b"\r\n", b"\n")).hexdigest()
            args.report.write_text(json.dumps(report, indent=2) + "\n")
            print("PASS: " + str(args.report), flush=True)
        except Exception:
            failed = True
            if args.layout == "single":
                print(run(["docker", "logs", "--tail", "100", stack.name]), flush=True)
            else:
                print(run(stack.compose + ["logs", "--tail", "30"]), flush=True)
            print("Failed disposable target: " + stack.name, flush=True)
            raise
        finally:
            if not (failed and args.keep_on_failure):
                stack.close()

if __name__ == "__main__":
    main()
