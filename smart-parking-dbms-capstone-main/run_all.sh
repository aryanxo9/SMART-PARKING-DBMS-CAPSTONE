#!/usr/bin/env bash
# Usage:  ./run_all.sh [mysql-user]      (prompts for the password once per file)
# Requires MySQL 8.0.31+ (INTERSECT/EXCEPT, FOR UPDATE SKIP LOCKED, CHECK constraints)
set -e
U="${1:-root}"
for f in 01_schema 02_functions_procedures_triggers 03_seed_data 04_views_indexes 07_security_rbac 08_star_schema_etl; do
  echo ">>> sql/$f.sql"; mysql -u "$U" -p < "sql/$f.sql"
done
echo ">>> queries (read the output)";  mysql -u "$U" -p --table < sql/05_queries.sql
echo ">>> test cases";                 mysql -u "$U" -p --table --force < sql/09_test_cases.sql
echo "Concurrency demo: open two terminals and follow sql/06_transactions_concurrency.sql (Part B),"
echo "or run:  python app/parking_app.py --concurrency"
echo "MongoDB: mongosh mongodb/gate_events.js"
