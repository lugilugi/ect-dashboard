FROM timescale/timescaledb:2.17.2-pg16

# Copy SQL migrations and setup scripts directly to the initialization directory
COPY db/migrations/001_telemetry_schema.sql /docker-entrypoint-initdb.d/01_telemetry_schema.sql
COPY db/migrations/002_indexes_policies.sql /docker-entrypoint-initdb.d/02_indexes_policies.sql
COPY db/migrations/003_command_and_recovery_audit.sql /docker-entrypoint-initdb.d/03_command_and_recovery_audit.sql
COPY db/migrations/004_query_performance_views.sql /docker-entrypoint-initdb.d/04_query_performance_views.sql
COPY ops/local-stack/bootstrap/10_local_roles.sql /docker-entrypoint-initdb.d/05_local_roles.sql
COPY db/scripts/verify_setup.sql /docker-entrypoint-initdb.d/06_verify_setup.sql
