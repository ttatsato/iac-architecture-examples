# PGのPrimaryとStandbyサーバーを立ち上げてWALを確認する

## 環境の準備

```sh
docker compose up -d
```

## サーバーに接続して動作確認

connect primary server

```sh
docker exec -it pg-primary psql -U postgres -d app
```

connect standby server

```sh
docker exec -it pg-standby psql -U postgres -d app
```

## replication確認

Primaryで：

```sql
SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;
```

```
app=# SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;
 application_name | client_addr |   state   | sync_state
------------------+-------------+-----------+------------
 walreceiver      | 172.20.0.10 | streaming | async
```

### LSN確認

Primary

```sql
SELECT pg_current_wal_lsn();

# pg_current_wal_lsn
# --------------------
#  0/3000110
```

## standby server で walを確認

Standby

```sql
SELECT
pg_last_wal_receive_lsn(),
pg_last_wal_replay_lsn();
```

```
pg_last_wal_receive_lsn | pg_last_wal_replay_lsn
-------------------------+------------------------
 0/3000110               | 0/3000110
(1 row)
```

→ 立ち上げ時はWALがまだ使われていない。

## テストデータ投入

Primaryでテストデータを大量投入して

```sql
CREATE TABLE test(id serial PRIMARY KEY,name text);
INSERT INTO test(name) SELECT md5(random()::text) FROM generate_series(1,300000);
SELECT count(*) FROM test;
```

Standbyに反映されているかを確認

```sql
SELECT count(*) FROM test;
```

Hot Standby が有効なら SELECT 可能です。

```
# app=# SELECT count(*) FROM test;
# count
# --------
# 300000
```

⸻

## replication lagで遅延を確認

Primaryで：

```sql
SELECT application_name, client_addr,
pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn) AS sent_lag_bytes,
pg_wal_lsn_diff(sent_lsn, write_lsn) AS write_lag_bytes,
pg_wal_lsn_diff(write_lsn, flush_lsn) AS flush_lag_bytes,
pg_wal_lsn_diff(flush_lsn, replay_lsn) AS replay_lag_bytes
FROM pg_stat_replication;
```

primary:

```
 application_name | client_addr | sent_lag_bytes | write_lag_bytes | flush_lag_bytes | replay_lag_bytes
------------------+-------------+----------------+-----------------+-----------------+------------------
 walreceiver      | 172.20.0.10 |              0 |               0 |               0 |                0
```

⸻

## WAL統計確認

primary:

```sql
SELECT wal_records, wal_fpi, wal_bytes, wal_buffers_full FROM pg_stat_wal;

# wal_records | wal_fpi | wal_bytes | wal_buffers_full
# -------------+---------+-----------+------------------
#       434171 |    1482 |  42266986 |             4907
```

standby:

```
 wal_records | wal_fpi | wal_bytes | wal_buffers_full
-------------+---------+-----------+------------------
           0 |       0 |         0 |                0
```

→ WALはローカルサーバーが生成したWALの統計なので、primaryだけが数値を持つ。正。

⸻

## Full Page Image を増やしてみる

checkpoint直後に大量更新すると
wal_fpi が増えます。

```sql
CHECKPOINT;
SELECT wal_records, wal_fpi, wal_bytes, wal_buffers_full FROM pg_stat_wal;
# wal_records | wal_fpi | wal_bytes | wal_buffers_full
# -------------+---------+-----------+------------------
#      638332 |    1491 |  58464502 |             6294
# (1 row)

UPDATE test SET name = md5(random()::text);
# UPDATE 300000
SELECT wal_fpi FROM pg_stat_wal;
# wal_fpi
# ---------
#    4815
```

⸻

## WALファイル確認

SELECT
name,
size,
modification
FROM pg_ls_waldir()
ORDER BY modification DESC;

primary:

```
           name           |   size   |      modification
--------------------------+----------+------------------------
 00000001000000000000000C | 16777216 | 2026-05-21 02:34:41+00
 00000001000000000000000B | 16777216 | 2026-05-21 02:26:06+00
 000000010000000000000007 | 16777216 | 2026-05-21 02:25:30+00
 000000010000000000000008 | 16777216 | 2026-05-21 02:25:30+00
 000000010000000000000009 | 16777216 | 2026-05-21 02:25:30+00
 00000001000000000000000A | 16777216 | 2026-05-21 02:25:30+00
 000000010000000000000005 | 16777216 | 2026-05-21 02:25:29+00
 000000010000000000000006 | 16777216 | 2026-05-21 02:25:29+00
 000000010000000000000004 | 16777216 | 2026-05-21 02:22:57+00
 000000010000000000000003 | 16777216 | 2026-05-21 02:08:06+00
 000000010000000000000001 | 16777216 | 2026-05-21 02:00:28+00
 000000010000000000000002 | 16777216 | 2026-05-21 02:00:28+00
(12 rows)
```

standby:

```
           name           |   size   |      modification
--------------------------+----------+------------------------
 00000001000000000000000C | 16777216 | 2026-05-21 02:34:41+00
 00000001000000000000000B | 16777216 | 2026-05-21 02:26:06+00
 000000010000000000000008 | 16777216 | 2026-05-21 02:25:30+00
 00000001000000000000000A | 16777216 | 2026-05-21 02:25:30+00
 000000010000000000000009 | 16777216 | 2026-05-21 02:25:30+00
 000000010000000000000007 | 16777216 | 2026-05-21 02:25:30+00
 000000010000000000000005 | 16777216 | 2026-05-21 02:25:29+00
 000000010000000000000006 | 16777216 | 2026-05-21 02:25:29+00
(8 rows)
```

→ タイムスタンプがprimaryとstandby間で一致している。
rowの数が違うのはなぜ？
- primary は `wal_keep_size = 256MB` と replication slot のために古い WAL を多めに保持している
- standby は replay 済みの WAL を逐次リサイクル(削除)していく
ため、primary 側の方がファイル数が多いのが通常。

⸻

## WAL総サイズ確認

```sql
SELECT
pg_size_pretty(sum(size)) AS total_wal_size
FROM pg_ls_waldir();
```

⸻

### replication slot確認

standby側がどこまでWALを読み込んだかを正確に記録しておくためのテーブル。

primary:
primary側の最新のLSN

```sql
SELECT pg_current_wal_lsn();
# pg_current_wal_lsn
# --------------------
#  0/C28B3B8
(1 row)

```

スタンバイ側が読み終えた最新のLSN

```sql
SELECT * FROM pg_replication_slots;
#  slot_name   | plugin | slot_type | datoid | database | temporary | active | active_pid | xmin | catalog_xmin | restart_lsn | confirmed_flush_lsn | wal_status | safe_wal_size | two_phase | conflicting
# --------------+--------+-----------+--------+----------+-----------+--------+------------+------+--------------+-------------+---------------------+------------+---------------+-----------+-------------
#  replica_slot |        | physical  |        |          | f         | t      |         34 |      |              | 0/C28B3B8   |                     | reserved   |               | f         |
```

→ `restart_lsn` は「primary がこの slot のために保持し続ける必要のある最古の WAL 位置」。
standby が消費した分だけ前に進むので、`pg_current_wal_lsn` と一致しているということは、
primary が直近で書いた位置まで standby が消費済み(=最新まで追いついている)と言える。

⸻

## standby遅延を意図的に発生させる

まずスタンバイ側でWALの受信はするが、データファイルへの反映(replay)はストップするようにする。

```sql
# standby
SELECT pg_wal_replay_pause();
```

Primaryで大量書き込み：

```sql
# primary
INSERT INTO test(name)
SELECT md5(random()::text)
FROM generate_series(1,1000000);
```

遅延確認SQLを実行する。

```sql
# primary
SELECT
    application_name,
    pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn) AS sent_lag_bytes,
    pg_wal_lsn_diff(sent_lsn, write_lsn) AS write_lag_bytes,
    pg_wal_lsn_diff(write_lsn, flush_lsn) AS flush_lag_bytes,
    pg_wal_lsn_diff(flush_lsn, replay_lsn) AS replay_lag_bytes
FROM pg_stat_replication;

#  application_name | sent_lag_bytes | write_lag_bytes | flush_lag_bytes | replay_lag_bytes
# ------------------+----------------+-----------------+-----------------+------------------
# walreceiver      |              0 |               0 |               0 |        165734256
```

→ replay_lag_bytesに大量のデータがあることを確認できる。
これはreplayが遅延していることを示している。

スタンバイ側でリプレイを再開させる

```sql
# standby
SELECT pg_wal_replay_resume();
```

再度、遅延確認SQLを実行する

```sql
SELECT
    application_name,
    pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn) AS sent_lag_bytes,
    pg_wal_lsn_diff(sent_lsn, write_lsn) AS write_lag_bytes,
    pg_wal_lsn_diff(write_lsn, flush_lsn) AS flush_lag_bytes,
    pg_wal_lsn_diff(flush_lsn, replay_lsn) AS replay_lag_bytes
FROM pg_stat_replication;

# application_name | sent_lag_bytes | write_lag_bytes | flush_lag_bytes | replay_lag_bytes
# ------------------+----------------+-----------------+-----------------+------------------
#  walreceiver      |              0 |               0 |               0 |                0
# (1 row)
```

→ replay_lag_bytesは0
つまり遅延なくstandby に取り込めた。

⸻

## Hot Standby確認

自サーバーがスタンドバイ環境であるかを確認

Standbyで：

```sql
# standby
SELECT pg_is_in_recovery();
# pg_is_in_recovery
# -------------------
# t
```

⸻

## Read replicaとしての働きができるか？

recovery中でもSELECT可能確認

```sql
# primary
SELECT count(*) FROM test;
#   count
# ---------
#  1300000
```

```sql
# standby
SELECT count(*) FROM test;
#   count
# ---------
#  1300000
```

→ primaryとstandby のレコード数が一致すればHot Standby有効です。
