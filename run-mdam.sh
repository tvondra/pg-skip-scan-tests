#!/usr/bin/bash -x

# exit on error
set -e

DBNAME=test
LABEL=$1

DATADIR=/mnt/pgdata/data-skip-scan
DUMPS=/mnt/pgdata/dumps-skip-scan
BUILDSDIR=/mnt/data/builds

PATH_OLD=$PATH

# number of rows to generate
ROWS="1000000"
#ROWS="10000000"

# number of distinct values
DISTINCT="100 1000 10000 100000 1000000 10000000"
#DISTINCT="1000 100000 10000000"

# number of index columns
COLUMNS="1 2 3 4"

# how skewed should the dataset be?
# 1 means no skew (uniform distribution), >1 means skew
SKEW="1 2 4 8"

# serial or parallel?
MAX_WORKERS="8"

# number of random queries to run for each combination of parameters
QUERIES=20

# number of runs for each query
RUNS=3

# number of values in the IN() clause
MAX_VALUES="1024"

BUILDS="16 master-fix patched-v6-fix"
#BUILDS="master"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS=results-$LABEL-$TIMESTAMP.csv
DEBUG=logs/debug-$LABEL-$TIMESTAMP.csv
QUERY_LOG=queries-$LABEL-$TIMESTAMP.csv
EXPLAIN=explain-$LABEL-$TIMESTAMP.log
ANALYZE=analyze-$LABEL-$TIMESTAMP.log
PRNG=random-$LABEL-$TIMESTAMP.log

killall postgres || true
rm -f $DATADIR/*/postmaster.pid

sleep 1

# simple deterministic pseudorandom generator - seed and max are enough
# to fully determine the result for a particular value
function prng_next() {

	v=$1
	min=$2
	max=$3

	# we'll do modulo
	max=$((max+1))

	# random produces only values 0-32768, so transform it into big integer
	# by hashing, and modulo
	h=$(echo $v | md5sum | awk '{print $1}')

	h=${h^^}

	# interpret hash as hex representation of integer
	x=$(echo "ibase=16; $h" | bc)

	r=$(echo "$min + $x % ($max - $min)" | bc)

	echo "$v $h $x $min $max $r" >> $PRNG 2>&1

	echo $r;
}

SEQ=0
QID=0

echo "SEQ QID date build rows distinct skew columns predicates seed workers query run scan caching hash_seq hash total planning execution count_is count_ios count_bis count_gather count_workers planned_is planned_ios planned_bis planned_gather row_count buff_hit buff_read buff_total index_searches optimal predicates" > $RESULTS

for rows in $ROWS; do

	for distinct in $DISTINCT; do

		# too many distinct values (more than rows)
		if [[ $distinct -gt $rows ]]; then
			continue
		fi

		for skew in $SKEW; do

			for columns in $COLUMNS; do

				for build in $BUILDS; do

					export PATH=$BUILDSDIR/$build/bin:$PATH_OLD

					echo $PATH

					pg_ctl -D $DATADIR/$build -l logs/$build.log start >> $DEBUG 2>&1
					dropdb test || true
					createdb test || true

					echo "========== build $build rows $rows distinct $distinct skew $skew columns $columns ==========" >> $DEBUG 2>&1

					table="t_${rows}_${distinct}_${skew}_${columns}"

					# do we already have the table?

					c=$(psql $DBNAME -t -A -c "select count(*) from pg_class where relname = '$table'")
					if [ "$c" == "0" ]; then

						if [ -f "$DUMPS/${table}.dump" ]; then

							cat "$DUMPS/${table}.dump" | psql test >> $DEBUG 2>&1

                                                        psql $DBNAME -c "vacuum freeze" >> $DEBUG 2>&1
                                                        psql $DBNAME -c "vacuum analyze" >> $DEBUG 2>&1
                                                        psql $DBNAME -c "checkpoint" >> $DEBUG 2>&1


						else

							cols="id1 bigint"
							keys="id1"
							exprs="(pow(random(), $skew) * $distinct)"

							for c in $(seq 2 $columns); do
								cols="$cols,id${c} bigint"
								keys="$keys,id${c}"
								exprs="$exprs,(pow(random(), $skew) * $distinct)"
							done

							psql $DBNAME -c "create table $table ($cols, val text)" >> $DEBUG 2>&1
							psql $DBNAME -c "insert into $table select $exprs, md5(i::text) from generate_series(1,$rows) s(i)" >> $DEBUG 2>&1
							psql $DBNAME -c "create index on $table ($keys)" >> $DEBUG 2>&1
							psql $DBNAME -c "vacuum freeze" >> $DEBUG 2>&1
							psql $DBNAME -c "vacuum analyze" >> $DEBUG 2>&1
							psql $DBNAME -c "vacuum freeze" >> $DEBUG 2>&1
							psql $DBNAME -c "checkpoint" >> $DEBUG 2>&1

							# dump the table
							pg_dump test -t "$table" > "$DUMPS/${table}.dump" 2> $DEBUG

						fi
					fi

					keys="id1"
					for c in $(seq 2 $columns); do
						keys="$keys,id${c}"
					done

					pg_ctl -D $DATADIR/$build -l logs/$build.log stop >> $DEBUG 2>&1

				done

				# generate the expected number of queries
				for query in $(seq 1 $QUERIES); do

					# seed for this particular combination of parameters
					prng_seed=$(((389 * rows) + (24593 * distinct) + (skew * 769) + (query * 98317)))
					RANDOM=$prng_seed

					echo "===== SEQ $SEQ SEED $prng_seed" >> $PRNG 2>&1

					# how many workers to use for this query?
					rand=$RANDOM
					num_workers=$(prng_next $rand 0 $MAX_WORKERS)

					# how many predicates for this query?
					rand=$RANDOM
					num_predicates=$(prng_next $rand 1 $columns)

					# generate the predicates
					predicates=""
					preficates_desc=""
					for p in $(seq 1 $num_predicates); do

						predicate=""
						predicate_desc=""

						# column for the predicate
						rand=$RANDOM
						c=$(prng_next $rand 1 $columns)

						# predicate type (1 => equality, 2 => range, 3 => IN)
						rand=$RANDOM
						t=$(prng_next $rand 1 3)

						if [ "$t" == "1" ]; then

							# single value equality
							rand=$rand
							val=$(prng_next $rand 0 $distinct)

							predicate="(id${c} = $val)"
							predicate_desc="(id${c} = VALUE)"

						elif [ "$t" == "2" ]; then

							# generate min/max values
							rand=$RANDOM
							val1=$(prng_next $rand 0 $distinct)

							rand=$RANDOM
							val2=$(prng_next $rand $val1 $distinct)

							predicate="(id${c} between $val1 and $val2)"
							predicate_desc="(id${c} between VALUE and VALUE)"

						elif [ "$t" == "3" ]; then

							max=$((distinct/2))
							if [[ $max -gt $MAX_VALUES ]]; then
								max=$MAX_VALUES
							fi

							# how many values into the IN() list?
							rand=$RANDOM
							cnt=$(prng_next $rand 1 $max)

							values=""

							for v in $(seq 1 $cnt); do

								rand=$RANDOM
								val=$(prng_next $rand 0 $distinct)

								if [ "$values" != "" ]; then
									values="$values, $val"
								else
									values="$val"
								fi
							done
							predicate="(id${c} in ($values))"
							predicate_desc="(id${c} in (LIST($cnt)))"

						fi

						# randomly negate the predicate
						rand=$RANDOM
						r=$(prng_next $rand 0 1)
						if [ "$r" == "1" ]; then
							predicate="NOT $predicate"
							predicate_desc="NOT $predicate_desc"
						fi

						# XXX maybe consider OR and NOT for the predicates too
						if [ "$predicates" != "" ]; then

							# make it random AND/OR
							rand=$RANDOM
							r=$(prng_next $rand 0 1)

							if [ "$r" == "0" ]; then
								conn="AND"
							else
								conn="OR"
							fi

							predicates="$predicates $conn $predicate"
							predicates_desc="$predicates_desc $conn $predicate_desc"
						else
							predicates="$predicate"
							predicates_desc="$predicate_desc"
						fi

					done

					echo "========== build $build workers $num_workers predicates $num_predicates =========="

					# INDEX SCAN

					QID=$((QID+1))
					sql="select ctid, * from $table where $predicates"

					echo $QID "$sql" >> $QUERY_LOG

					for run in $(seq 1 $RUNS); do

						for build in $BUILDS; do

							export PATH=$BUILDSDIR/$build/bin:$PATH_OLD

							pg_ctl -D $DATADIR/$build -l logs/$build.log start >> $DEBUG 2>&1

                                                        pages=$(psql -t -A test -c "select relpages from pg_class where relname = '$table'")
                                                        allvisible=$(psql -t -A test -c "select relallvisible from pg_class where relname = '$table'")
                                                        echo "table: $table $pages $allvisible"

							# first, see what plan we would get without forcing index scan
							psql $DBNAME > tmp/explain.log <<EOF
-- to make parallel queries likely (if enabled)
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET min_parallel_index_scan_size = 0;
-- force index scan
SET max_parallel_workers_per_gather = $num_workers;
explain $sql;
EOF

							# count different plan types
							planned_is=$(grep 'Index Scan' tmp/explain.log | wc -l)
							planned_ios=$(grep 'Index Only Scan' tmp/explain.log | wc -l)
							planned_bis=$(grep 'Bitmap Heap Scan' tmp/explain.log | wc -l)
							planned_gather=$(grep 'Gather' tmp/explain.log | wc -l)

							if [ "$count_is" != "0" ] && [ "$planned_is" == "$count_is" ] && [ "$planned_bis" == "$count_bis" ] && [ "$planned_ios" == "$count_ios" ]; then
								optimal="yes";
							else
								optimal="no";
							fi

							psql $DBNAME > tmp/explain.log <<EOF
-- to make parallel queries likely (if enabled)
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET min_parallel_index_scan_size = 0;
-- force index scan
SET max_parallel_workers_per_gather = $num_workers;
SET enable_bitmapscan = off;
SET enable_seqscan = off;
explain $sql;
EOF

							# count different plan types
							count_is=$(grep 'Index Scan' tmp/explain.log | wc -l)
							count_ios=$(grep 'Index Only Scan' tmp/explain.log | wc -l)
							count_bis=$(grep 'Bitmap Heap Scan' tmp/explain.log | wc -l)
							count_gather=$(grep 'Gather' tmp/explain.log | wc -l)

							# no index scan, no point in timing this
							#if [ "$count_is" == "0" ]; then
							#	echo "skipping $SEQ query $QID build $build (no index scan)"
							#	pg_ctl -D $DATADIR/$build -l logs/$build.log stop >> $DEBUG 2>&1
							#	continue
							#fi

							SEQ=$((SEQ+1))

							echo "===== $SEQ build $build SQL: $sql run $run index-scan =====" >> $EXPLAIN 2>&1
							echo "$sql" >> $EXPLAIN 2>&1
							cat tmp/explain.log  >> $EXPLAIN 2>&1

							# hash of results (first by seqscan as "truth")
							rm -f tmp/output1
							psql -t -A $DBNAME >> logs/hash.log <<EOF
-- force seq scan
SET enable_bitmapscan = off;
SET enable_indexscan = off;
\o tmp/output1
$sql;
EOF

							hash_seq=$(sort tmp/output1 | md5sum | awk '{print $1}')
							row_count=$(cat tmp/output1 | wc -l)

							# now with the index scan, for comparison
							rm -f tmp/output2
							psql -t -A $DBNAME >> logs/hash.log <<EOF
-- to make parallel queries likely (if enabled)
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET min_parallel_index_scan_size = 0;
-- force index scan
SET max_parallel_workers_per_gather = $num_workers;
SET enable_bitmapscan = off;
SET enable_seqscan = off;
\o tmp/output2
$sql;
EOF

							hash=$(sort tmp/output2 | md5sum | awk '{print $1}')

							if [ "$hash_seq" != "$hash" ]; then
								echo "invalid hash - index scan"
								echo $sql;
								exit 1
							fi

							# uncached
							pg_ctl -D $DATADIR/$build -l logs/pg.log restart >> $DEBUG 2>&1
							sudo ./drop-caches.sh >> $DEBUG 2>&1

							psql $DBNAME > tmp/analyze.log <<EOF
\timing on
-- to make parallel queries likely (if enabled)
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET min_parallel_index_scan_size = 0;
-- force index scan
SET max_parallel_workers_per_gather = $num_workers;
SET enable_bitmapscan = off;
SET enable_seqscan = off;
explain (analyze, buffers, timing off) $sql;
EOF

							# count workers used to run the plan
							count_workers=$(grep 'Workers Launched' tmp/analyze.log | awk '{print $3}')
							if [ "$count_workers" == "" ]; then
								count_workers="0";
							fi

							echo "===== $SEQ build $build SQL: $sql run $run index-scan not-ncached =====" >> $ANALYZE 2>&1
							echo "$sql" >> $ANALYZE 2>&1
							cat tmp/analyze.log  >> $ANALYZE 2>&1

							t=$(grep '^Time:' tmp/analyze.log | awk '{print $2}' | tail -n 1)
							pt=$(grep 'Planning Time:' tmp/analyze.log | awk '{print $3}' | tail -n 1)
							et=$(grep 'Execution Time:' tmp/analyze.log | awk '{print $3}' | tail -n 1)

							buff_hit=$(grep 'Buffers:' tmp/analyze.log | grep 'hit' | sed 's/.*hit=\([0-9]\+\).*/\1/' | awk '{ SUM += $1} END { print SUM }')
							buff_read=$(grep 'Buffers:' tmp/analyze.log | grep 'read' | sed 's/.*read=\([0-9]\+\).*/\1/' | awk '{ SUM += $1} END { print SUM }')
							index_searches=$(grep 'Index Searches:' tmp/analyze.log | awk '{ SUM += $3} END { print SUM }')

							if [ "$buff_hit" == "" ]; then buff_hit="0"; fi
							if [ "$buff_read" == "" ]; then buff_read="0"; fi
							if [ "$index_searches" == "" ]; then index_searches="0"; fi

							buff_total=$((buff_hit+buff_read))

							echo $SEQ $QID $(date +%s) $build $rows $distinct $skew $columns $num_predicates $prng_seed $num_workers $query $run index-scan not-cached $hash_seq $hash $t $pt $et $count_is $count_ios $count_bis $count_gather $count_workers $planned_is $planned_ios $planned_bis $planned_gather $row_count $buff_hit $buff_read $buff_total $index_searches $optimal "'$predicates_desc'" >> $RESULTS

							SEQ=$((SEQ+1))

							# cached
							psql $DBNAME > tmp/analyze.log <<EOF
\timing on
-- to make parallel queries likely (if enabled)
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET min_parallel_index_scan_size = 0;
-- force index scan
SET max_parallel_workers_per_gather = $num_workers;
SET enable_bitmapscan = off;
SET enable_seqscan = off;
explain (analyze, buffers, timing off) $sql;
EOF

							count_workers=$(grep 'Workers Launched' tmp/analyze.log | awk '{print $3}')
							if [ "$count_$workers" == "" ]; then
								count_workers="0";
							fi

							echo "===== $SEQ $build $sql run $run index-scan cached =====" >> $ANALYZE 2>&1
							echo "$sql" >> $ANALYZE 2>&1
							cat tmp/analyze.log  >> $ANALYZE 2>&1

							t=$(grep '^Time:' tmp/analyze.log | awk '{print $2}' | tail -n 1)
							pt=$(grep 'Planning Time:' tmp/analyze.log | awk '{print $3}' | tail -n 1)
							et=$(grep 'Execution Time:' tmp/analyze.log | awk '{print $3}' | tail -n 1)

                                                        buff_hit=$(grep 'Buffers:' tmp/analyze.log | grep 'hit' | sed 's/.*hit=\([0-9]\+\).*/\1/' | awk '{ SUM += $1} END { print SUM }')
                                                        buff_read=$(grep 'Buffers:' tmp/analyze.log | grep 'read' | sed 's/.*read=\([0-9]\+\).*/\1/' | awk '{ SUM += $1} END { print SUM }')
                                                        index_searches=$(grep 'Index Searches:' tmp/analyze.log | awk '{ SUM += $3} END { print SUM }')

                                                        if [ "$buff_hit" == "" ]; then buff_hit="0"; fi
                                                        if [ "$buff_read" == "" ]; then buff_read="0"; fi
                                                        if [ "$index_searches" == "" ]; then index_searches="0"; fi

							buff_total=$((buff_hit+buff_read))

							echo $SEQ $QID $(date +%s) $build $rows $distinct $skew $columns $num_predicates $prng_seed $num_workers $query $run index-scan cached $hash_seq $hash $t $pt $et $count_is $count_ios $count_bis $count_gather $count_workers $planned_is $planned_ios $planned_bis $planned_gather $row_count $buff_hit $buff_read $buff_total $index_searches $optimal "'$predicates_desc'" >> $RESULTS


							pg_ctl -D $DATADIR/$build -l logs/$build.log stop >> $DEBUG 2>&1

						done

					done


					# INDEX-ONLY SCAN

					QID=$((QID+1))
					sql="select $keys from $table where $predicates"

					echo $QID "$sql" >> $QUERY_LOG

					for run in $(seq 1 $RUNS); do

						for build in $BUILDS; do

							export PATH=$BUILDSDIR/$build/bin:$PATH_OLD

							pg_ctl -D $DATADIR/$build -l logs/$build.log start >> $DEBUG 2>&1

                                                        pages=$(psql -t -A test -c "select relpages from pg_class where relname = '$table'")
                                                        allvisible=$(psql -t -A test -c "select relallvisible from pg_class where relname = '$table'")
                                                        echo "table: $table $pages $allvisible"

							# first, see what plan we would get without forcing index-only scan
							psql $DBNAME > tmp/explain.log <<EOF
-- to make parallel queries likely (if enabled)
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET min_parallel_index_scan_size = 0;
-- force index scan
SET max_parallel_workers_per_gather = $num_workers;
explain $sql;
EOF

							# count different plan types
							planned_is=$(grep 'Index Scan' tmp/explain.log | wc -l)
							planned_ios=$(grep 'Index Only Scan' tmp/explain.log | wc -l)
							planned_bis=$(grep 'Bitmap Heap Scan' tmp/explain.log | wc -l)
							planned_gather=$(grep 'Gather' tmp/explain.log | wc -l)

							if [ "$count_ios" != "0" ] && [ "$planned_is" == "$count_is" ] && [ "$planned_bis" == "$count_bis" ] && [ "$planned_ios" == "$count_ios" ]; then
								optimal="yes";
							else
								optimal="no";
							fi

							psql $DBNAME > tmp/explain.log <<EOF
-- to make parallel queries likely (if enabled)
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET min_parallel_index_scan_size = 0;
-- force index scan
SET max_parallel_workers_per_gather = $num_workers;
SET enable_bitmapscan = off;
SET enable_seqscan = off;
explain $sql;
EOF

							# count different plan types
							count_is=$(grep 'Index Scan' tmp/explain.log | wc -l)
							count_ios=$(grep 'Index Only Scan' tmp/explain.log | wc -l)
							count_bis=$(grep 'Bitmap Heap Scan' tmp/explain.log | wc -l)
							count_gather=$(grep 'Gather' tmp/explain.log | wc -l)

							# no index-only scan, no point in timing this
							#if [ "$count_ios" == "0" ]; then
							#	echo "skipping $SEQ query $QID build $build (no index-only scan)"
							#	pg_ctl -D $DATADIR/$build -l logs/$build.log stop >> $DEBUG 2>&1
							#	continue
							#fi

							# hash of results (first by seqscan as "truth")
							rm -f tmp/output3
							psql -t -A $DBNAME >> logs/hash.log <<EOF
-- force seq scan
SET enable_bitmapscan = off;
SET enable_indexscan = off;
\o tmp/output3
$sql;
EOF

							hash_seq=$(sort tmp/output3 | md5sum | awk '{print $1}')

							# hash of results
							rm -f tmp/output4
							psql -t -A $DBNAME >> logs/hash.log <<EOF
-- to make parallel queries likely (if enabled)
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET min_parallel_index_scan_size = 0;
-- force index scan
SET max_parallel_workers_per_gather = $num_workers;
SET enable_bitmapscan = off;
SET enable_seqscan = off;
\o tmp/output4
$sql;
EOF

							hash=$(sort tmp/output4 | md5sum | awk '{print $1}')
							if [ "$hash_seq" != "$hash" ]; then
									echo "invalid hash - index scan"
									echo $sql;
									exit 1
							fi

							SEQ=$((SEQ+1))

							echo "===== $SEQ $build $sql run $run index-only-scan =====" >> $EXPLAIN 2>&1
							echo "$sql" >> $EXPLAIN 2>&1
							cat tmp/explain.log  >> $EXPLAIN 2>&1

							# uncached
							pg_ctl -D $DATADIR/$build -l logs/pg.log restart >> $DEBUG 2>&1
							sudo ./drop-caches.sh >> $DEBUG 2>&1

							psql $DBNAME > tmp/analyze.log <<EOF
\timing on
-- to make parallel queries likely (if enabled)
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET min_parallel_index_scan_size = 0;
-- force index scan
SET max_parallel_workers_per_gather = $num_workers;
SET enable_bitmapscan = off;
SET enable_seqscan = off;
explain (analyze, buffers, timing off) $sql;
EOF

							count_workers=$(grep 'Workers Launched' tmp/analyze.log | awk '{print $3}')
							if [ "$count_workers" == "" ]; then
								count_workers="0";
							fi

							echo "===== $SEQ $build $sql run $run index-only-scan not-cached =====" >> $ANALYZE 2>&1
							echo "$sql" >> $ANALYZE 2>&1
							cat tmp/analyze.log  >> $ANALYZE 2>&1

							t=$(grep '^Time:' tmp/analyze.log | awk '{print $2}' | tail -n 1)
							pt=$(grep 'Planning Time:' tmp/analyze.log | awk '{print $3}' | tail -n 1)
							et=$(grep 'Execution Time:' tmp/analyze.log | awk '{print $3}' | tail -n 1)

                                                        buff_hit=$(grep 'Buffers:' tmp/analyze.log | grep 'hit' | sed 's/.*hit=\([0-9]\+\).*/\1/' | awk '{ SUM += $1} END { print SUM }')
                                                        buff_read=$(grep 'Buffers:' tmp/analyze.log | grep 'read' | sed 's/.*read=\([0-9]\+\).*/\1/' | awk '{ SUM += $1} END { print SUM }')
                                                        index_searches=$(grep 'Index Searches:' tmp/analyze.log | awk '{ SUM += $3} END { print SUM }')

                                                        if [ "$buff_hit" == "" ]; then buff_hit="0"; fi
                                                        if [ "$buff_read" == "" ]; then buff_read="0"; fi
                                                        if [ "$index_searches" == "" ]; then index_searches="0"; fi

							buff_total=$((buff_hit+buff_read))

							echo $SEQ $QID $(date +%s) $build $rows $distinct $skew $columns $num_predicates $prng_seed $num_workers $query $run index-only-scan not-cached $hash_seq $hash $t $pt $et $count_is $count_ios $count_bis $count_gather $count_workers $planned_is $planned_ios $planned_bis $planned_gather $row_count $buff_hit $buff_read $buff_total $index_searches $optimal "'$predicates_desc'" >> $RESULTS

							SEQ=$((SEQ+1))

							# cached
							psql $DBNAME > tmp/analyze.log <<EOF
\timing on
-- to make parallel queries likely (if enabled)
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET min_parallel_index_scan_size = 0;
-- force index scan
SET max_parallel_workers_per_gather = $num_workers;
SET enable_bitmapscan = off;
SET enable_seqscan = off;
explain (analyze, buffers, timing off) $sql;
EOF

							count_workers=$(grep 'Workers Launched' tmp/analyze.log | awk '{print $3}')
							if [ "$count_workers" == "" ]; then
								count_workers="0";
							fi

							echo "===== $SEQ $build $sql run $run index-only-scan cached =====" >> $ANALYZE 2>&1
							echo "$sql" >> $ANALYZE 2>&1
							cat tmp/analyze.log  >> $ANALYZE 2>&1

							t=$(grep '^Time:' tmp/analyze.log | awk '{print $2}' | tail -n 1)
							pt=$(grep 'Planning Time:' tmp/analyze.log | awk '{print $3}' | tail -n 1)
							et=$(grep 'Execution Time:' tmp/analyze.log | awk '{print $3}' | tail -n 1)

                                                        buff_hit=$(grep 'Buffers:' tmp/analyze.log | grep 'hit' | sed 's/.*hit=\([0-9]\+\).*/\1/' | awk '{ SUM += $1} END { print SUM }')
                                                        buff_read=$(grep 'Buffers:' tmp/analyze.log | grep 'read' | sed 's/.*read=\([0-9]\+\).*/\1/' | awk '{ SUM += $1} END { print SUM }')
                                                        index_searches=$(grep 'Index Searches:' tmp/analyze.log | awk '{ SUM += $3} END { print SUM }')

                                                        if [ "$buff_hit" == "" ]; then buff_hit="0"; fi
                                                        if [ "$buff_read" == "" ]; then buff_read="0"; fi
                                                        if [ "$index_searches" == "" ]; then index_searches="0"; fi

							buff_total=$((buff_hit+buff_read))

							echo $SEQ $QID $(date +%s) $build $rows $distinct $skew $columns $num_predicates $prng_seed $num_workers $query $run index-only-scan cached $hash_seq $hash $t $pt $et $count_is $count_ios $count_bis $count_gather $count_workers $planned_is $planned_ios $planned_bis $planned_gather $row_count $buff_hit $buff_read $buff_total $index_searches $optimal "'$predicates_desc'" >> $RESULTS

							pg_ctl -D $DATADIR/$build -l logs/$build.log stop >> $DEBUG 2>&1

						done

					done

				done

			done

		done

	done

done
