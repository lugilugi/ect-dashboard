# Mosquitto Ops Notes

This folder contains a baseline broker sample config for the telemetry pipeline.

## Files

- `mosquitto.conf.sample`: Base broker options with persistence and ACL/password auth.

## Queue sizing

`max_queued_bytes` (1.5 GB per client) bounds an offline subscriber's backlog
(about 2 hours at 400 records/s); `max_queued_messages` is only a backstop.
`autosave_interval 30` means a broker crash can lose up to 30 s of queued
messages; the phone's 7-day history and the reconcile tool cover that.
Watch `$SYS/broker/messages/stored` (enabled via `sys_interval`).

## Suggested ACL

Create `/etc/mosquitto/acl`:

```conf
user car_uplink
topic write telemetry/eco_archers/events

user telegraf
topic read telemetry/eco_archers/events
```

## Suggested Password Setup

```bash
sudo mosquitto_passwd -c /etc/mosquitto/passwd car_uplink
sudo mosquitto_passwd /etc/mosquitto/passwd telegraf
```

## Restart and Verify

```bash
sudo systemctl restart mosquitto
sudo systemctl status mosquitto
```

## Security Baseline

- Keep `allow_anonymous false`.
- Scope write/read ACLs tightly per topic.
- Prefer binding to a trusted interface/VPN subnet.
- Enable TLS in production if traffic leaves trusted transport overlays.
