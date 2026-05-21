CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator';

SELECT pg_create_physical_replication_slot('replica_slot');
