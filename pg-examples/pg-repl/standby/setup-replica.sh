#!/bin/bash
set -e

mkdir -p /var/lib/postgresql/data
chown -R postgres:postgres /var/lib/postgresql/data
chmod 700 /var/lib/postgresql/data

if [ ! -s "/var/lib/postgresql/data/PG_VERSION" ]; then

  gosu postgres bash -c 'rm -rf /var/lib/postgresql/data/*'

  export PGPASSWORD=replicator

  until gosu postgres pg_basebackup \
    -h primary \
    -D /var/lib/postgresql/data \
    -U replicator \
    -Fp \
    -Xs \
    -P \
    -R
  do
    echo "waiting for primary..."
    sleep 2
  done

  gosu postgres bash -c 'cat >> /var/lib/postgresql/data/postgresql.auto.conf' <<EOF
primary_conninfo = 'host=primary port=5432 user=replicator password=replicator'
primary_slot_name = 'replica_slot'
hot_standby = on
EOF

fi

exec gosu postgres postgres
