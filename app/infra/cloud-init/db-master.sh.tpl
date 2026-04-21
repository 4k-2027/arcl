#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y postgresql postgresql-contrib python3-pip python3-dev libpq-dev curl etcd

pip3 install --quiet patroni[etcd] psycopg2-binary

PG_VERSION=14
PG_DATA=/etc/patroni

# --- etcd (DCS local, single node pour la démo) ---
cat > /etc/default/etcd << EOF
ETCD_NAME="etcd0"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_LISTEN_CLIENT_URLS="http://0.0.0.0:2379"
ETCD_ADVERTISE_CLIENT_URLS="http://${master_ip}:2379"
ETCD_LISTEN_PEER_URLS="http://0.0.0.0:2380"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${master_ip}:2380"
ETCD_INITIAL_CLUSTER="etcd0=http://${master_ip}:2380"
ETCD_INITIAL_CLUSTER_TOKEN="todo-cluster"
ETCD_INITIAL_CLUSTER_STATE="new"
EOF

systemctl enable etcd
systemctl start etcd

# --- Patroni ---
systemctl stop postgresql || true
systemctl disable postgresql || true

mkdir -p /data/patroni
chown postgres:postgres /data/patroni
chmod 700 /data/patroni

cat > /etc/patroni.yml << EOF
scope: todo-db
namespace: /db/
name: db-master

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${master_ip}:8008

etcd:
  host: ${master_ip}:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 5
        max_replication_slots: 5

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - host replication replicator 0.0.0.0/0 md5
    - host all all 0.0.0.0/0 md5

  users:
    ${db_user}:
      password: "${db_password}"
      options:
        - createdb
    replicator:
      password: "${replication_password}"
      options:
        - replication

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${master_ip}:5432
  data_dir: /data/patroni
  bin_dir: /usr/lib/postgresql/$PG_VERSION/bin
  authentication:
    replication:
      username: replicator
      password: "${replication_password}"
    superuser:
      username: postgres
      password: "${db_password}"

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF

cat > /etc/systemd/system/patroni.service << 'EOF'
[Unit]
Description=Patroni
After=network.target etcd.service

[Service]
User=postgres
ExecStart=/usr/local/bin/patroni /etc/patroni.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable patroni
systemctl start patroni

# Attendre que Patroni init PostgreSQL puis créer le schéma
sleep 30
sudo -u postgres /usr/lib/postgresql/$PG_VERSION/bin/psql -h 127.0.0.1 -U postgres -d ${db_name} -c "
CREATE TABLE IF NOT EXISTS todos (
    id SERIAL PRIMARY KEY,
    title TEXT NOT NULL,
    done BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);" || true
