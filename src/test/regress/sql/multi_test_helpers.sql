-- File to create functions and helpers needed for subsequent tests

-- create a helper function to create objects on each node
CREATE OR REPLACE FUNCTION run_command_on_master_and_workers(p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
     EXECUTE p_sql;
     PERFORM run_command_on_workers(p_sql);
END;$$;

-- Create a function to make sure that queries returning the same result
CREATE OR REPLACE FUNCTION raise_failed_execution(query text) RETURNS void AS $$
BEGIN
	EXECUTE query;
	EXCEPTION WHEN OTHERS THEN
	IF SQLERRM LIKE 'failed to execute task%' THEN
		RAISE 'Task failed to execute';
	END IF;
END;
$$LANGUAGE plpgsql;

-- Create a function to ignore worker plans in explain output
CREATE OR REPLACE FUNCTION coordinator_plan(explain_command text, out query_plan text)
RETURNS SETOF TEXT AS $$
BEGIN
  FOR query_plan IN execute explain_command LOOP
    RETURN next;
    IF query_plan LIKE '%Task Count:%'
    THEN
        RETURN;
    END IF;
  END LOOP;
  RETURN;
END; $$ language plpgsql;

-- helper function that returns true if output of given explain has "is not null" (case in-sensitive)
CREATE OR REPLACE FUNCTION explain_has_is_not_null(explain_command text)
RETURNS BOOLEAN AS $$
DECLARE
  query_plan text;
BEGIN
  FOR query_plan IN EXECUTE explain_command LOOP
    IF query_plan ILIKE '%is not null%'
    THEN
        RETURN true;
    END IF;
  END LOOP;
  RETURN false;
END; $$ language plpgsql;

-- helper function that returns true if output of given explain has "is not null" (case in-sensitive)
CREATE OR REPLACE FUNCTION explain_has_distributed_subplan(explain_command text)
RETURNS BOOLEAN AS $$
DECLARE
  query_plan text;
BEGIN
  FOR query_plan IN EXECUTE explain_command LOOP
    IF query_plan ILIKE '%Distributed Subplan %_%'
    THEN
        RETURN true;
    END IF;
  END LOOP;
  RETURN false;
END; $$ language plpgsql;

--helper function to check there is a single task
CREATE OR REPLACE FUNCTION explain_has_single_task(explain_command text)
RETURNS BOOLEAN AS $$
DECLARE
  query_plan text;
BEGIN
  FOR query_plan IN EXECUTE explain_command LOOP
    IF query_plan ILIKE '%Task Count: 1%'
    THEN
        RETURN true;
    END IF;
  END LOOP;
  RETURN false;
END; $$ language plpgsql;

-- helper function to quickly run SQL on the whole cluster
CREATE OR REPLACE FUNCTION run_command_on_coordinator_and_workers(p_sql text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
     EXECUTE p_sql;
     PERFORM run_command_on_workers(p_sql);
END;$$;

-- 1. Marks the given procedure as colocated with the given table.
-- 2. Marks the argument index with which we route the procedure.
CREATE OR REPLACE FUNCTION colocate_proc_with_table(procname text, tablerelid regclass, argument_index int)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    update pg_catalog.pg_dist_object
    set distribution_argument_index = argument_index, colocationid = pg_dist_partition.colocationid
    from pg_proc, pg_dist_partition
    where proname = procname and oid = objid and pg_dist_partition.logicalrelid = tablerelid;
END;$$;

-- helper function to verify the function of a coordinator is the same on all workers
CREATE OR REPLACE FUNCTION verify_function_is_same_on_workers(funcname text)
    RETURNS bool
    LANGUAGE plpgsql
AS $func$
DECLARE
    coordinatorSql text;
    workerSql text;
BEGIN
    SELECT pg_get_functiondef(funcname::regprocedure) INTO coordinatorSql;
    FOR workerSql IN SELECT result FROM run_command_on_workers('SELECT pg_get_functiondef(' || quote_literal(funcname) || '::regprocedure)') LOOP
            IF workerSql != coordinatorSql THEN
                RAISE INFO 'functions are different, coordinator:% worker:%', coordinatorSql, workerSql;
                RETURN false;
            END IF;
        END LOOP;

    RETURN true;
END;
$func$;

--
-- Procedure for creating shards for range partitioned distributed table.
--
CREATE OR REPLACE PROCEDURE create_range_partitioned_shards(rel regclass, minvalues text[], maxvalues text[])
AS $$
DECLARE
  new_shardid bigint;
  idx int;
BEGIN
  FOR idx IN SELECT * FROM generate_series(1, array_length(minvalues, 1))
  LOOP
    SELECT master_create_empty_shard(rel::text) INTO new_shardid;
    UPDATE pg_dist_shard SET shardminvalue=minvalues[idx], shardmaxvalue=maxvalues[idx] WHERE shardid=new_shardid;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

\c - - - :worker_1_port
-- Create replication slots for targetNode1 and targetNode2
CREATE OR REPLACE FUNCTION CreateReplicationSlot(targetNode1 integer, targetNode2 integer) RETURNS text AS $$
DECLARE
    targetOneSlotName text;
    targetTwoSlotName text;
    sharedMemoryId text;
    derivedSlotName text;
begin

    SELECT * into sharedMemoryId from public.SplitShardReplicationSetup(targetNode1, targetNode2);
    SELECT FORMAT('%s_%s', targetNode1, sharedMemoryId) into derivedSlotName;
    SELECT slot_name into targetOneSlotName from pg_create_logical_replication_slot(derivedSlotName, 'decoding_plugin_for_shard_split');

    -- if new child shards are placed on different nodes, create one more replication slot
    if (targetNode1 != targetNode2) then
        SELECT FORMAT('%s_%s', targetNode2, sharedMemoryId) into derivedSlotName;
        SELECT slot_name into targetTwoSlotName from pg_create_logical_replication_slot(derivedSlotName, 'decoding_plugin_for_shard_split');
        INSERT INTO slotName_table values(targetTwoSlotName, targetNode2, 1);
    end if;

    INSERT INTO slotName_table values(targetOneSlotName, targetNode1, 2);
    return targetOneSlotName;
end
$$ LANGUAGE plpgsql;

-- targetNode1, targetNode2 are the locations where childShard1 and childShard2 are placed respectively
CREATE OR REPLACE FUNCTION SplitShardReplicationSetup(targetNode1 integer, targetNode2 integer) RETURNS text AS $$
DECLARE
    memoryId bigint := 0;
    memoryIdText text;
begin
	SELECT * into memoryId from split_shard_replication_setup(ARRAY[ARRAY[1,2,-2147483648,-1, targetNode1], ARRAY[1,3,0,2147483647,targetNode2]]);
    SELECT FORMAT('%s', memoryId) into memoryIdText;
    return memoryIdText;
end
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION CreateSubscription(targetNodeId integer, subscriptionName text) RETURNS text AS $$
DECLARE
    replicationSlotName text;
    nodeportLocal int;
    subname text;
begin
    SELECT name into replicationSlotName from slotName_table where nodeId = targetNodeId;
    EXECUTE FORMAT($sub$create subscription %s connection 'host=localhost port=57637 user=postgres dbname=regression' publication PUB1 with(create_slot=false, enabled=true, slot_name='%s', copy_data=false)$sub$, subscriptionName, replicationSlotName);
    return 'a';
end
$$ LANGUAGE plpgsql;

\c - - - :worker_2_port
CREATE OR REPLACE FUNCTION CreateSubscription(targetNodeId integer, subscriptionName text) RETURNS text AS $$
DECLARE
    replicationSlotName text;
    nodeportLocal int;
    subname text;
begin
    SELECT name into replicationSlotName from slotName_table where nodeId = targetNodeId;
    EXECUTE FORMAT($sub$create subscription %s connection 'host=localhost port=57637 user=postgres dbname=regression' publication PUB1 with(create_slot=false, enabled=true, slot_name='%s', copy_data=false)$sub$, subscriptionName, replicationSlotName);
    return 'a';
end
$$ LANGUAGE plpgsql;

