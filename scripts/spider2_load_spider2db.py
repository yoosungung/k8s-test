#!/usr/bin/env python3
"""Load Spider2-Lite sqlite metadata into PostgreSQL spider2db.

Each folder under resource/databases/sqlite becomes a schema.
Tables/columns come from DDL.csv; rows from *.json sample_rows.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

SQLITE_INTERNAL_TABLE = re.compile(r"^sqlite_", re.I)
JUNCTION_TABLE_SUFFIXES = (
    "_details",
    "_items",
    "_track",
    "_demo",
    "_territories",
    "_mapping",
)

TYPE_MAP = {
    "INTEGER": "BIGINT",
    "INT": "BIGINT",
    "BIGINT": "BIGINT",
    "SMALLINT": "SMALLINT",
    "BLOB SUB_TYPE TEXT": "TEXT",
    "TEXT": "TEXT",
    "NVARCHAR": "VARCHAR",
    "VARCHAR": "VARCHAR",
    "CHAR": "CHAR",
    "REAL": "REAL",
    "FLOAT": "DOUBLE PRECISION",
    "DOUBLE": "DOUBLE PRECISION",
    "NUMERIC": "NUMERIC",
    "DECIMAL": "NUMERIC",
    "BOOLEAN": "BOOLEAN",
    "DATE": "DATE",
    "DATETIME": "TIMESTAMP",
    "TIMESTAMP": "TIMESTAMP",
    "BLOB": "BYTEA",
}


def is_pk_candidate(col: str) -> bool:
    if col.endswith("Id"):
        return True
    if col.endswith("_id"):
        return True
    if col.endswith("id"):
        # Avoid false positives such as cust_valid / prod_valid.
        if col.endswith(("valid", "guid")):
            return False
        return len(col) > 2
    return False


def entity_pk_name_variants(table_name: str) -> set[str]:
    t = table_name.lower().replace("-", "_")
    variants: set[str] = set()

    def add_base(base: str) -> None:
        b = base.replace("_", "")
        if not b:
            return
        variants.add(f"{b}id")
        variants.add(f"{b}_id")

    add_base(t)
    add_base(t.replace("_", ""))
    if t.endswith("ies"):
        add_base(t[:-3] + "y")
    elif t.endswith("s") and not t.endswith("ss"):
        add_base(t[:-1])
    if t.endswith("_items"):
        stem = t[: -len("_items")]
        add_base(f"{stem}line")
        add_base(f"{stem}_line")
    if t.endswith("_item"):
        stem = t[: -len("_item")]
        add_base(f"{stem}line")
    if "_" in t:
        for part in reversed(t.split("_")):
            if part in {
                "hierarchy",
                "details",
                "items",
                "item",
                "track",
                "demo",
                "territories",
                "mapping",
                "events",
                "users",
                "transactions",
                "nodes",
                "center",
                "data",
            }:
                continue
            add_base(part)
    return variants


def find_entity_pk(table_name: str, candidates: list[str]) -> str | None:
    variants = entity_pk_name_variants(table_name)
    for col in candidates:
        normalized = col.lower().replace("_", "")
        for variant in variants:
            if normalized == variant.replace("_", ""):
                return col
    if "item" in table_name.lower() or "line" in table_name.lower():
        for col in candidates:
            if "line" in col.lower() and col.lower().endswith("id"):
                return col
    return None


def is_junction_table(table_name: str) -> bool:
    lowered = table_name.lower()
    return any(lowered.endswith(suffix) for suffix in JUNCTION_TABLE_SUFFIXES)


def infer_pk_columns(
    table_name: str,
    columns: list[str],
    column_types: dict[str, str] | None = None,
) -> list[str]:
    candidates: list[str] = []
    for col in columns:
        if not is_pk_candidate(col):
            continue
        if column_types is not None:
            if base_type(column_types.get(col, "TEXT")) not in {
                "INTEGER",
                "INT",
                "BIGINT",
                "SMALLINT",
            }:
                continue
        candidates.append(col)
    if not candidates:
        return []
    if len(candidates) == 1:
        return candidates
    if columns and all(is_pk_candidate(c) for c in columns):
        return candidates
    entity = find_entity_pk(table_name, candidates)
    if entity:
        return [entity]
    for col in candidates:
        if col.lower() == "businessentityid":
            return [col]
    if is_junction_table(table_name) and len(candidates) >= 2:
        return candidates
    return [candidates[0]]


def parse_column_def(part: str) -> tuple[str, str]:
    part = part.strip()
    for compound, mapped in sorted(
        ((k, v) for k, v in TYPE_MAP.items() if " " in k),
        key=lambda item: len(item[0]),
        reverse=True,
    ):
        if part.upper().endswith(compound):
            name = part[: -len(compound)].strip().strip('"[]`')
            return name, mapped
    for type_name in sorted(
        (k for k in TYPE_MAP if " " not in k), key=len, reverse=True
    ):
        pattern = rf"\s+{re.escape(type_name)}(\([^)]*\))?\s*$"
        match = re.search(pattern, part, re.I)
        if not match:
            continue
        name = part[: match.start()].strip().strip('"[]`')
        raw_type = part[match.start() :].strip()
        base = type_name.upper()
        mapped = TYPE_MAP[base]
        if "(" in raw_type and mapped in ("VARCHAR", "NUMERIC", "CHAR"):
            return name, f"{mapped}{raw_type[raw_type.find('('):]}"
        return name, mapped
    tokens = part.split(None, 1)
    name = tokens[0].strip('"[]`')
    return name, "TEXT"


def parse_table_columns(ddl: str) -> list[tuple[str, str]]:
    match = re.search(r"\((.*)\)\s*;?\s*$", ddl, re.S | re.I)
    if not match:
        raise ValueError(f"Could not parse DDL: {ddl[:120]}...")
    body = match.group(1)
    columns: list[tuple[str, str]] = []
    for part in re.split(r",(?![^(]*\))", body):
        part = part.strip()
        if not part:
            continue
        columns.append(parse_column_def(part))
    return columns


def quote_ident(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def base_type(col_type: str) -> str:
    return col_type.upper().split("(", 1)[0].strip()


def is_numeric_type(col_type: str) -> bool:
    base = base_type(col_type)
    return base in {
        "INTEGER",
        "INT",
        "BIGINT",
        "SMALLINT",
        "REAL",
        "FLOAT",
        "DOUBLE",
        "NUMERIC",
        "DECIMAL",
        "BOOLEAN",
        "DATE",
        "DATETIME",
        "TIMESTAMP",
    }


def sql_literal(value: Any, col_type: str | None = None) -> str:
    if value is None:
        return "NULL"
    if col_type and base_type(col_type) == "BOOLEAN":
        if value == "":
            return "NULL"
        if isinstance(value, bool):
            return "TRUE" if value else "FALSE"
        if value in (0, 1, "0", "1"):
            return "TRUE" if str(value) == "1" else "FALSE"
    if value == "" and col_type and is_numeric_type(col_type):
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
        return "NULL"
    if isinstance(value, (int, float)):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"


def pg_schema_name(folder_name: str) -> str:
    return folder_name.lower()


def build_create_table(schema: str, table: str, columns: list[tuple[str, str]], pk_cols: list[str]) -> str:
    lines: list[str] = []
    pk_set = set(pk_cols)
    for name, col_type in columns:
        line = f"  {quote_ident(name)} {col_type}"
        if name in pk_set and len(pk_cols) == 1:
            line += " PRIMARY KEY"
        lines.append(line)
    ddl = f"CREATE TABLE {quote_ident(schema)}.{quote_ident(table)} (\n"
    ddl += ",\n".join(lines)
    if len(pk_cols) > 1:
        pk = ", ".join(quote_ident(c) for c in pk_cols)
        ddl += f",\n  PRIMARY KEY ({pk})"
    ddl += "\n);"
    return ddl


def load_schema_folder(schema_dir: Path) -> list[str]:
    schema = pg_schema_name(schema_dir.name)
    statements: list[str] = [
        f"DROP SCHEMA IF EXISTS {quote_ident(schema)} CASCADE;",
        f"CREATE SCHEMA {quote_ident(schema)};",
    ]

    ddl_path = schema_dir / "DDL.csv"
    if not ddl_path.exists():
        return statements

    with ddl_path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            table = row["table_name"].strip()
            if SQLITE_INTERNAL_TABLE.match(table) or table.upper() == "ERD":
                continue
            columns = parse_table_columns(row["DDL"])
            if not columns:
                continue
            col_names = [name for name, _ in columns]
            type_map = {name: col_type for name, col_type in columns}
            pk_cols = infer_pk_columns(table, col_names, type_map)
            statements.append(
                f"DROP TABLE IF EXISTS {quote_ident(schema)}.{quote_ident(table)} CASCADE;"
            )
            statements.append(build_create_table(schema, table, columns, pk_cols))

            json_path = schema_dir / f"{table}.json"
            if not json_path.exists():
                continue
            payload = json.loads(json_path.read_text(encoding="utf-8"))
            rows = payload.get("sample_rows") or []
            if not rows:
                continue
            json_cols = payload.get("column_names") or col_names
            ddl_col_set = set(col_names)
            insert_cols = [c for c in json_cols if c in ddl_col_set]
            if not insert_cols:
                insert_cols = col_names
            deduped_rows: list[dict[str, Any]] = []
            seen: set[tuple[Any, ...]] = set()
            for record in rows:
                key = tuple(record.get(c) for c in insert_cols)
                if key in seen:
                    continue
                seen.add(key)
                deduped_rows.append(record)
            rows = deduped_rows
            if not rows:
                continue
            col_types = payload.get("column_types") or []
            type_by_col = dict(zip(insert_cols, col_types))
            col_sql = ", ".join(quote_ident(c) for c in insert_cols)
            value_rows: list[str] = []
            for record in rows:
                values = ", ".join(
                    sql_literal(record.get(c), type_by_col.get(c))
                    for c in insert_cols
                )
                value_rows.append(f"({values})")
            statements.append(
                f"INSERT INTO {quote_ident(schema)}.{quote_ident(table)} ({col_sql}) VALUES\n"
                + ",\n".join(value_rows)
                + " ON CONFLICT DO NOTHING;"
            )
    return statements


def run_psql_batch(
    sql: str,
    *,
    namespace: str,
    pod: str,
    database: str,
) -> None:
    shell = (
        'export PGPASSWORD="$(cat /opt/bitnami/postgresql/secrets/postgres-password)" && '
        f"psql -v ON_ERROR_STOP=1 -U postgres -d {database}"
    )
    proc = subprocess.run(
        [
            "kubectl",
            "exec",
            "-i",
            "-n",
            namespace,
            pod,
            "--",
            "/bin/bash",
            "-lc",
            shell,
        ],
        input=sql.encode("utf-8"),
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr.decode("utf-8", errors="replace"))
        raise RuntimeError(f"psql failed with exit code {proc.returncode}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--sqlite-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1]
        / ".tmp-spider2/spider2-lite/resource/databases/sqlite",
        help="Path to Spider2 sqlite resource directory",
    )
    parser.add_argument("--namespace", default="postgres")
    parser.add_argument("--pod", default="postgresql-0")
    parser.add_argument("--database", default="spider2db")
    args = parser.parse_args()

    if not args.sqlite_dir.is_dir():
        print(f"sqlite dir not found: {args.sqlite_dir}", file=sys.stderr)
        return 1

    schema_dirs = sorted(
        path for path in args.sqlite_dir.iterdir() if path.is_dir()
    )
    if not schema_dirs:
        print(f"no schema folders in {args.sqlite_dir}", file=sys.stderr)
        return 1

    for schema_dir in schema_dirs:
        statements = load_schema_folder(schema_dir)
        if len(statements) <= 1:
            continue
        sql = "BEGIN;\n" + "\n".join(statements) + "\nCOMMIT;\n"
        print(f"Loading schema {pg_schema_name(schema_dir.name)} ...")
        run_psql_batch(sql, namespace=args.namespace, pod=args.pod, database=args.database)

    verify_sql = (
        "SELECT n.nspname AS schema, count(*) AS tables "
        "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE c.relkind = 'r' AND n.nspname NOT LIKE 'pg_%' "
        "AND n.nspname <> 'information_schema' "
        "GROUP BY n.nspname ORDER BY 1;"
    )
    proc = subprocess.run(
        [
            "kubectl",
            "exec",
            "-n",
            args.namespace,
            args.pod,
            "--",
            "/bin/bash",
            "-lc",
            (
                'export PGPASSWORD="$(cat /opt/bitnami/postgresql/secrets/postgres-password)" && '
                f'psql -U postgres -d {args.database} -c "{verify_sql}"'
            ),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    print(proc.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
