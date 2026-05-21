#!/bin/bash
set -e

cat > "$PGDATA/pg_hba.conf" <<'EOF'
local all all trust
host all all 172.20.0.0/16 scram-sha-256
host replication replicator 172.20.0.10/32 scram-sha-256
EOF

psql -U postgres -c "SELECT pg_reload_conf();"
