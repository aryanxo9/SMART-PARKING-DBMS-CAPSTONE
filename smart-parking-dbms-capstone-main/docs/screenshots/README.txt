Screenshot index (what each one proves)
01 schema created (file 01)              -> DDL
02/03 two sessions, same slot            -> concurrency, overlap rejected
04 session B waited ~25 s then failed    -> row lock / blocking
05 queries file 05 all green             -> complex SQL
06 prepared statement returns 0 rows     -> SQL-injection prevention
07 star schema ETL results (file 08)     -> CO4 ETL / OLAP
08 test cases file 09 completed          -> testing
09 invariants all 0                      -> integrity proof
10 reservations on slot 15               -> no double booking in data
11 T5 transaction scenario               -> business rule 10-12 / 11-13 / 12-14

STILL TO CAPTURE (see chat): T1 COMMIT, T2 ROLLBACK, T3 SAVEPOINT, Q1/Q4/Q5/Q7 results,
injection Result 3 (70 rows) + Result 4, ROLLUP result, DCL role grants, EXPLAIN before/after.
