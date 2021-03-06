-- Memory consumption of operators 

-- start_ignore
create schema memconsumption;
set search_path to memconsumption;
-- end_ignore

create table test (i int, j int);

set explain_memory_verbosity=detail;
set execute_pruned_plan=on;

insert into test select i, i % 100 from generate_series(1,1000) as i;

-- start_ignore
create language plpythonu;
-- end_ignore

create or replace function sum_alien_consumption(query text) returns int as
$$
import re
rv = plpy.execute('EXPLAIN ANALYZE '+ query)
search_text = 'X_Alien'
total_consumption = 0
count = 0
comp_regex = re.compile("[^0-9]+(\d+)\/(\d+).+")
for i in range(len(rv)):
    cur_line = rv[i]['QUERY PLAN']
    if search_text.lower() in cur_line.lower():
        print search_text
        m = comp_regex.match(cur_line)
        if m is not None:
            count = count + 1
            total_consumption = total_consumption + int(m.group(2))
return total_consumption
$$
language plpythonu;

select sum_alien_consumption('SELECT t1.i, t2.j FROM test as t1 join test as t2 on t1.i = t2.j') = 0;

set execute_pruned_plan=off;
select sum_alien_consumption('SELECT t1.i, t2.j FROM test as t1 join test as t2 on t1.i = t2.j') > 0;

create or replace function has_account_type(query text, search_text text) returns int as
$$
import re
rv = plpy.execute('EXPLAIN ANALYZE '+ query)
comp_regex = re.compile("^\s+%s" % search_text)
count = 0
for i in range(len(rv)):
    cur_line = rv[i]['QUERY PLAN']
    m = comp_regex.match(cur_line)
    if m is not None:
        count = count + 1
return count
$$
language plpythonu;

-- Create functions that will generate nested SQL executors
CREATE OR REPLACE FUNCTION simple_plpgsql_function(int) RETURNS int AS $$
 DECLARE RESULT int;
BEGIN
 SELECT count(*) FROM pg_class INTO RESULT;
 RETURN RESULT + $1;
END;
$$ LANGUAGE plpgsql NO SQL;


CREATE OR REPLACE FUNCTION simple_sql_function(argument int) RETURNS bigint AS $$
SELECT count(*) + argument FROM pg_class;
$$ LANGUAGE SQL STRICT VOLATILE;

-- Create a table with tuples only on one segement
CREATE TABLE all_tuples_on_seg0(i int);
INSERT INTO all_tuples_on_seg0 VALUES (0), (0), (0);
SELECT gp_segment_id, count(*) FROM all_tuples_on_seg0 GROUP BY 1;

-- The X_NestedExecutor account is only created if we create an executor.
-- Because all the tuples in all_tuples_on_seg0 are on seg0, only seg0 should
-- create the X_NestedExecutor account.
set explain_memory_verbosity to detail;
-- We expect that only seg0 will create an X_NestedExecutor account, so this
-- should return '1'
select has_account_type('select simple_sql_function(i) from all_tuples_on_seg0', 'X_NestedExecutor');
-- Each node will create a 'main' executor account, so we expect that this
-- will return '3', one per Query Executor.
select has_account_type('select simple_sql_function(i) from all_tuples_on_seg0', 'Executor');
-- Same as above, this should return '1'
select has_account_type('select simple_plpgsql_function(i) from all_tuples_on_seg0', 'X_NestedExecutor');
-- Same as above, this should return '3'
select has_account_type('select simple_plpgsql_function(i) from all_tuples_on_seg0', 'Executor');

-- After setting explain_memory_verbosity to 'debug', the X_NestedExecutor
-- account will no longer be created. Instead, every time we evaluate a code
-- block in an sql or PL/pgSQL function, it will create a new executor account.
-- There are three tuples in all_tuples_on_seg0, so we should see three more
-- Executor accounts than when we had the explain_memory_verbosity guc set to
-- 'detail'.
set explain_memory_verbosity to debug;
-- We expect this will be '0'
select has_account_type('select simple_sql_function(i) from all_tuples_on_seg0', 'X_NestedExecutor');
-- Because there are three tuples in all_tuples_on_seg0, we expect to see three
-- additional 'Executor' accounts created, a total number of '6'.
select has_account_type('select simple_sql_function(i) from all_tuples_on_seg0', 'Executor');
-- Expect '0'
select has_account_type('select simple_plpgsql_function(i) from all_tuples_on_seg0', 'X_NestedExecutor');
-- Expect '6'
select has_account_type('select simple_plpgsql_function(i) from all_tuples_on_seg0', 'Executor');

-- Test X_NestedExecutor is created correctly inside multiple slice plans
set explain_memory_verbosity to detail;
-- We should see two TableScans- one per slice. Because only one segment has
-- tuples, only one segment per slice will create the 'X_NestedExecutor'
-- account. This will return '2'.
select has_account_type('select * from (select simple_sql_function(i) from all_tuples_on_seg0) a, (select simple_sql_function(i) from all_tuples_on_seg0) b', 'X_NestedExecutor');
-- There will be two slices, and each slice will create an 'Executor' account
-- for a total of '6' 'Executor' accounts.
select has_account_type('select * from (select simple_sql_function(i) from all_tuples_on_seg0) a, (select simple_sql_function(i) from all_tuples_on_seg0) b', 'Executor');


set explain_memory_verbosity to debug;
-- We don't create 'X_NestedExecutor' accounts when explain_memory_verbosity is
-- set to 'debug', so this will return '0'
select has_account_type('select * from (select simple_sql_function(i) from all_tuples_on_seg0) a, (select simple_sql_function(i) from all_tuples_on_seg0) b', 'X_NestedExecutor');
-- Two slices, each returning three tuples. For each tuple we will create an
-- 'Executor' account. We also expect one main 'Executor' account per slice, so
-- expect '12' total Executor accounts
select has_account_type('select * from (select simple_sql_function(i) from all_tuples_on_seg0) a, (select simple_sql_function(i) from all_tuples_on_seg0) b', 'Executor');
