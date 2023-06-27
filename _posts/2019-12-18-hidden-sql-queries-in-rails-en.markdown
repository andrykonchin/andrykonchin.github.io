---
layout:     post
title:      "Hidden SQL-queries in Rails"
date:       2019-12-18 00:43
categories: Rails
extra_head: |
  <style>
    pre code { white-space: pre; }
  </style>
---

Let's imagine what happens when we launch Rails console and make the
first SQL query to a database:

```
irb(main):001:0> Account.last
  Account Load (1.9ms)  SELECT  "accounts".* FROM "accounts" ORDER BY "accounts"."id" DESC LIMIT $1  [["LIMIT", 1]]
```

Rails builds an SQL-query, logs it and send to database to execute. Such SQL queries are flooding console output and development log files. But it's only visible interaction between Rails and a database. Let's look at invisible SQL queries that Rails executes under the hood.

### Establishing a new connection

Let's consider Rails 5.2 and PostgreSQL 12. If you launch Rails console and enter `Account.last`, then Rails executes a whole bunch of strange SQL-queries (other than fetching the most recent account):

```sql
SET client_min_messages TO 'warning'
SET standard_conforming_strings = on
SET SESSION timezone TO 'UTC'
            SELECT t.oid, t.typname
            FROM pg_type as t
            WHERE t.typname IN ('int2', 'int4', 'int8', 'oid', 'float4', 'float8', 'bool')

              SELECT t.oid, t.typname, t.typelem, t.typdelim, t.typinput, r.rngsubtype, t.typtype, t.typbasetype
              FROM pg_type as t
              LEFT JOIN pg_range as r ON oid = rngtypid
              WHERE
                t.typname IN ('int2', 'int4', 'int8', 'oid', 'float4', 'float8', 'text', 'varchar', 'char', 'name', 'bpchar', 'bool', 'bit', 'varbit', 'timestamptz', 'date', 'money', 'bytea', 'point', 'hstore', 'json', 'jsonb', 'cidr', 'inet', 'uuid', 'xml', 'tsvector', 'macaddr', 'citext', 'ltree', 'line', 'lseg', 'box', 'path', 'polygon', 'circle', 'interval', 'time', 'timestamp', 'numeric')
                OR t.typtype IN ('r', 'e', 'd')
                OR t.typinput = 'array_in(cstring,oid,integer)'::regprocedure
                OR t.typelem != 0

SHOW TIME ZONE
SELECT c.relname FROM pg_class c LEFT JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = ANY (current_schemas(false)) AND c.relkind IN ('r','v','m','p','f')
SELECT a.attname
  FROM (
         SELECT indrelid, indkey, generate_subscripts(indkey, 1) idx
           FROM pg_index
          WHERE indrelid = '"accounts"'::regclass
            AND indisprimary
       ) i
  JOIN pg_attribute a
    ON a.attrelid = i.indrelid
   AND a.attnum = i.indkey[i.idx]
 ORDER BY i.idx

SHOW search_path
SELECT  "accounts".* FROM "accounts" ORDER BY "accounts"."id" DESC LIMIT $1
              SELECT a.attname, format_type(a.atttypid, a.atttypmod),
                     pg_get_expr(d.adbin, d.adrelid), a.attnotnull, a.atttypid, a.atttypmod,
                     c.collname, col_description(a.attrelid, a.attnum) AS comment
                FROM pg_attribute a
                LEFT JOIN pg_attrdef d ON a.attrelid = d.adrelid AND a.attnum = d.adnum
                LEFT JOIN pg_type t ON a.atttypid = t.oid
                LEFT JOIN pg_collation c ON a.attcollation = c.oid AND a.attcollation <> t.typcollation
               WHERE a.attrelid = '"accounts"'::regclass
                 AND a.attnum > 0 AND NOT a.attisdropped
               ORDER BY a.attnum

SHOW max_identifier_length
```

Let's figure out what is happening here.

Rails establishes connection to a database lazily - only when it's nessecary - at the first SQL query to a database. That's why before `Account.last` is executed Rails hasn't establish any connection.

During the `last` method call Rails establishes and sets up the first connection to a database. To generate _accessors_ for a mode attributes and _type cast_ attribute values to a table column types Rails needs to know a table schema. These data is lazily loaded from a database at the first SQL query execution and are cached.

Lets's review each of the SQL query above in details.


### #1

```sql
SET client_min_messages TO 'warning'
```

Rails sets up `client_min_messages` option - level of client logging
(`warning` in our case). Postgres server writes system and user messages
into a log according to a logging level. For instance resulting parse
tree, the query rewriter output, or the execution plan for each executed
query. To send or not to send these messages to a client depends on
connection specific client logging level, that is by default `notice`.

Just for fun you can play with Postgres debug output - set the most
detailed logging level(`DEBUG1`) and enable logging, for instance,
execution plans and internal representation of SQL queries before and
after optimisation:

```sql
SET debug_print_plan      TO true;
SET debug_print_rewritten TO true;
SET debug_print_parse     TO true;

SET client_min_messages   TO 'DEBUG1';

SELECT * FROM accounts;               -- or any other SQL query
```

Debug output in PostgreSQL is a big topic on its own and deserves a
separate post. Just mention a few links:

- <https://www.postgresql.org/docs/12/runtime-config-client.html#GUC-CLIENT-MIN-MESSAGES>
- <https://www.postgresql.org/docs/12/runtime-config-logging.html#RUNTIME-CONFIG-SEVERITY-LEVELS>


### #2

```sql
SET standard_conforming_strings = on
```

The `standard_conforming_strings` option changes the way string literals
in SQL queries are interpreted. Particularly on intepretation of
*backslash*-sequences (`\n`, `\t`, ...). When it's on then
interpretation is disabled. Starting from PostgreSQL 9.1 this options is
on by default.

Links:
- <https://www.postgresql.org/docs/12/runtime-config-compatible.html#GUC-STANDARD-CONFORMING-STRINGS>
- <https://www.postgresql.org/docs/12/sql-syntax-lexical.html#SQL-SYNTAX-STRINGS-ESCAPE>


### #3

```sql
SET SESSION timezone TO 'UTC'
```

This command, it's obvious, sets _timezone_ for a connection. This
connection timezone is used in the following cases:
- when data is transmited to a database client time values with timezone
are converted to this connection timezone
- when data is transmited to a database server time literals without
explicit timezone are assigned this connection timezone

If timezone isn't set explicitly then the following rules are used:
- if on a client side an environment variable `PGTZ` is set - then a
client library `libpq` will use it and set connection timezone on its
own
- otherwise PostgreSQL on a server side will check whether timezone is
configured on a `postgresql.conf` file
- in case it isn't configured then a server local timezone is applied:
  - PostgreSQL check if an environment variable `TZ` presents
  - and only then uses system local timezone

Links:
- <https://www.postgresql.org/docs/12/runtime-config-client.html#GUC-TIMEZONE>
- <https://www.postgresql.org/docs/12/datatype-datetime.html#DATATYPE-TIMEZONES>


### #4

```sql
SELECT t.oid, t.typname
FROM pg_type as t
WHERE t.typname IN ('int2', 'int4', 'int8', 'oid', 'float4', 'float8', 'bool')
```

This way Rails obtains information about some essential types in PostgreSQL. The system table `pg_type` contains properties of builtin and custom user types. Rails fetches a type name and a primary key `oid`:

```
 oid | typname
-----+---------
  16 | bool
  20 | int8
  21 | int2
  23 | int4
  26 | oid
 700 | float4
 701 | float8
(7 rows)
```

<https://www.postgresql.org/docs/12/catalog-pg-type.html>


### #5

```sql
SELECT t.oid, t.typname, t.typelem, t.typdelim, t.typinput, r.rngsubtype, t.typtype, t.typbasetype
FROM pg_type as t
  LEFT JOIN pg_range as r ON oid = rngtypid
WHERE
  t.typname IN ('int2', 'int4', 'int8', 'oid', 'float4', 'float8', 'text', 'varchar', 'char', 'name', 'bpchar', 'bool', 'bit', 'varbit', 'timestamptz', 'date', 'money', 'bytea', 'point', 'hstore', 'json', 'jsonb', 'cidr', 'inet', 'uuid', 'xml', 'tsvector', 'macaddr', 'citext', 'ltree', 'line', 'lseg', 'box', 'path', 'polygon', 'circle', 'interval', 'time', 'timestamp', 'numeric')
  OR t.typtype IN ('r', 'e', 'd')
  OR t.typinput = 'array_in(cstring,oid,integer)'::regprocedure
  OR t.typelem != 0
```

This way Rails obtains properties of built in Postgres types (`t.typname IN
('int2', 'float4', 'text', 'varchar'...)`) and user
custom types as well - _ranges_, _enums_, _domains_ (`t.typtype IN ('r', 'e', 'd')`) and arrays (`t.typelem != 0`).

```
  oid  |        typname        | typelem | typdelim |    typinput    | rngsubtype | typtype | typbasetype
-------+-----------------------+---------+----------+----------------+------------+---------+-------------
    16 | bool                  |       0 | ,        | boolin         |            | b       |           0
    17 | bytea                 |       0 | ,        | byteain        |            | b       |           0
    18 | char                  |       0 | ,        | charin         |            | b       |           0
    19 | name                  |      18 | ,        | namein         |            | b       |           0
    20 | int8                  |       0 | ,        | int8in         |            | b       |           0
    21 | int2                  |       0 | ,        | int2in         |            | b       |           0
    22 | int2vector            |      21 | ,        | int2vectorin   |            | b       |           0
    23 | int4                  |       0 | ,        | int4in         |            | b       |           0
    25 | text                  |       0 | ,        | textin         |            | b       |           0
    26 | oid                   |       0 | ,        | oidin          |            | b       |           0
    30 | oidvector             |      26 | ,        | oidvectorin    |            | b       |           0
   114 | json                  |       0 | ,        | json_in        |            | b       |           0
   142 | xml                   |       0 | ,        | xml_in         |            | b       |           0
   600 | point                 |     701 | ,        | point_in       |            | b       |           0
   601 | lseg                  |     600 | ,        | lseg_in        |            | b       |           0
   602 | path                  |       0 | ,        | path_in        |            | b       |           0
   603 | box                   |     600 | ;        | box_in         |            | b       |           0
   604 | polygon               |       0 | ,        | poly_in        |            | b       |           0
   628 | line                  |     701 | ,        | line_in        |            | b       |           0
   700 | float4                |       0 | ,        | float4in       |            | b       |           0
   701 | float8                |       0 | ,        | float8in       |            | b       |           0
   718 | circle                |       0 | ,        | circle_in      |            | b       |           0
   790 | money                 |       0 | ,        | cash_in        |            | b       |           0
   829 | macaddr               |       0 | ,        | macaddr_in     |            | b       |           0
   869 | inet                  |       0 | ,        | inet_in        |            | b       |           0
   650 | cidr                  |       0 | ,        | cidr_in        |            | b       |           0
  1042 | bpchar                |       0 | ,        | bpcharin       |            | b       |           0
  1043 | varchar               |       0 | ,        | varcharin      |            | b       |           0
  1082 | date                  |       0 | ,        | date_in        |            | b       |           0
  1083 | time                  |       0 | ,        | time_in        |            | b       |           0
  1114 | timestamp             |       0 | ,        | timestamp_in   |            | b       |           0
  1184 | timestamptz           |       0 | ,        | timestamptz_in |            | b       |           0
  1186 | interval              |       0 | ,        | interval_in    |            | b       |           0
  1560 | bit                   |       0 | ,        | bit_in         |            | b       |           0
  1562 | varbit                |       0 | ,        | varbit_in      |            | b       |           0
  1700 | numeric               |       0 | ,        | numeric_in     |            | b       |           0
  2950 | uuid                  |       0 | ,        | uuid_in        |            | b       |           0
  3614 | tsvector              |       0 | ,        | tsvectorin     |            | b       |           0
  3802 | jsonb                 |       0 | ,        | jsonb_in       |            | b       |           0
  3904 | int4range             |       0 | ,        | range_in       |         23 | r       |           0
  3906 | numrange              |       0 | ,        | range_in       |       1700 | r       |           0
  3908 | tsrange               |       0 | ,        | range_in       |       1114 | r       |           0
  3910 | tstzrange             |       0 | ,        | range_in       |       1184 | r       |           0
  3912 | daterange             |       0 | ,        | range_in       |       1082 | r       |           0
  3926 | int8range             |       0 | ,        | range_in       |         20 | r       |           0
  2287 | _record               |    2249 | ,        | array_in       |            | p       |           0
  1000 | _bool                 |      16 | ,        | array_in       |            | b       |           0
  1001 | _bytea                |      17 | ,        | array_in       |            | b       |           0
  1002 | _char                 |      18 | ,        | array_in       |            | b       |           0
  1003 | _name                 |      19 | ,        | array_in       |            | b       |           0
  1016 | _int8                 |      20 | ,        | array_in       |            | b       |           0
  1005 | _int2                 |      21 | ,        | array_in       |            | b       |           0
  1006 | _int2vector           |      22 | ,        | array_in       |            | b       |           0
  1007 | _int4                 |      23 | ,        | array_in       |            | b       |           0
  1008 | _regproc              |      24 | ,        | array_in       |            | b       |           0
  1009 | _text                 |      25 | ,        | array_in       |            | b       |           0
  1028 | _oid                  |      26 | ,        | array_in       |            | b       |           0
  1010 | _tid                  |      27 | ,        | array_in       |            | b       |           0
  1011 | _xid                  |      28 | ,        | array_in       |            | b       |           0
  1012 | _cid                  |      29 | ,        | array_in       |            | b       |           0
  1013 | _oidvector            |      30 | ,        | array_in       |            | b       |           0
   199 | _json                 |     114 | ,        | array_in       |            | b       |           0
   143 | _xml                  |     142 | ,        | array_in       |            | b       |           0
  1017 | _point                |     600 | ,        | array_in       |            | b       |           0
  1018 | _lseg                 |     601 | ,        | array_in       |            | b       |           0
  1019 | _path                 |     602 | ,        | array_in       |            | b       |           0
  1020 | _box                  |     603 | ;        | array_in       |            | b       |           0
  1027 | _polygon              |     604 | ,        | array_in       |            | b       |           0
   629 | _line                 |     628 | ,        | array_in       |            | b       |           0
  1021 | _float4               |     700 | ,        | array_in       |            | b       |           0
  1022 | _float8               |     701 | ,        | array_in       |            | b       |           0
   719 | _circle               |     718 | ,        | array_in       |            | b       |           0
   791 | _money                |     790 | ,        | array_in       |            | b       |           0
  1040 | _macaddr              |     829 | ,        | array_in       |            | b       |           0
  1041 | _inet                 |     869 | ,        | array_in       |            | b       |           0
   651 | _cidr                 |     650 | ,        | array_in       |            | b       |           0
   775 | _macaddr8             |     774 | ,        | array_in       |            | b       |           0
  1034 | _aclitem              |    1033 | ,        | array_in       |            | b       |           0
  1014 | _bpchar               |    1042 | ,        | array_in       |            | b       |           0
  1015 | _varchar              |    1043 | ,        | array_in       |            | b       |           0
  1182 | _date                 |    1082 | ,        | array_in       |            | b       |           0
  1183 | _time                 |    1083 | ,        | array_in       |            | b       |           0
  1115 | _timestamp            |    1114 | ,        | array_in       |            | b       |           0
  1185 | _timestamptz          |    1184 | ,        | array_in       |            | b       |           0
  1187 | _interval             |    1186 | ,        | array_in       |            | b       |           0
  1270 | _timetz               |    1266 | ,        | array_in       |            | b       |           0
  1561 | _bit                  |    1560 | ,        | array_in       |            | b       |           0
  1563 | _varbit               |    1562 | ,        | array_in       |            | b       |           0
  1231 | _numeric              |    1700 | ,        | array_in       |            | b       |           0
  2201 | _refcursor            |    1790 | ,        | array_in       |            | b       |           0
  2207 | _regprocedure         |    2202 | ,        | array_in       |            | b       |           0
  2208 | _regoper              |    2203 | ,        | array_in       |            | b       |           0
  2209 | _regoperator          |    2204 | ,        | array_in       |            | b       |           0
  2210 | _regclass             |    2205 | ,        | array_in       |            | b       |           0
  2211 | _regtype              |    2206 | ,        | array_in       |            | b       |           0
  4097 | _regrole              |    4096 | ,        | array_in       |            | b       |           0
  4090 | _regnamespace         |    4089 | ,        | array_in       |            | b       |           0
  2951 | _uuid                 |    2950 | ,        | array_in       |            | b       |           0
  3221 | _pg_lsn               |    3220 | ,        | array_in       |            | b       |           0
  3643 | _tsvector             |    3614 | ,        | array_in       |            | b       |           0
  3644 | _gtsvector            |    3642 | ,        | array_in       |            | b       |           0
  3645 | _tsquery              |    3615 | ,        | array_in       |            | b       |           0
  3735 | _regconfig            |    3734 | ,        | array_in       |            | b       |           0
  3770 | _regdictionary        |    3769 | ,        | array_in       |            | b       |           0
  3807 | _jsonb                |    3802 | ,        | array_in       |            | b       |           0
  4073 | _jsonpath             |    4072 | ,        | array_in       |            | b       |           0
  2949 | _txid_snapshot        |    2970 | ,        | array_in       |            | b       |           0
  3905 | _int4range            |    3904 | ,        | array_in       |            | b       |           0
  3907 | _numrange             |    3906 | ,        | array_in       |            | b       |           0
  3909 | _tsrange              |    3908 | ,        | array_in       |            | b       |           0
  3911 | _tstzrange            |    3910 | ,        | array_in       |            | b       |           0
  3913 | _daterange            |    3912 | ,        | array_in       |            | b       |           0
  3927 | _int8range            |    3926 | ,        | array_in       |            | b       |           0
  1263 | _cstring              |    2275 | ,        | array_in       |            | b       |           0
 16387 | _schema_migrations    |   16388 | ,        | array_in       |            | b       |           0
 13402 | cardinal_number       |       0 | ,        | domain_in      |            | d       |          23
 13401 | _cardinal_number      |   13402 | ,        | array_in       |            | b       |           0
 13405 | character_data        |       0 | ,        | domain_in      |            | d       |        1043
 13404 | _character_data       |   13405 | ,        | array_in       |            | b       |           0
 13407 | sql_identifier        |       0 | ,        | domain_in      |            | d       |          19
 13406 | _sql_identifier       |   13407 | ,        | array_in       |            | b       |           0
 13412 | time_stamp            |       0 | ,        | domain_in      |            | d       |        1184
 13411 | _time_stamp           |   13412 | ,        | array_in       |            | b       |           0
 13414 | yes_or_no             |       0 | ,        | domain_in      |            | d       |        1043
 13413 | _yes_or_no            |   13414 | ,        | array_in       |            | b       |           0
 16395 | _ar_internal_metadata |   16396 | ,        | array_in       |            | b       |           0
 16405 | _accounts             |   16406 | ,        | array_in       |            | b       |           0
 16416 | _payments             |   16417 | ,        | array_in       |            | b       |           0
(128 rows)
```


### #6

```sql
SELECT c.relname FROM pg_class c LEFT JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = ANY (current_schemas(false)) AND c.relkind IN ('r','v','m','p','f')
```

Rails fetches lists of tables, _views_, _materialized views_,
_partitioned tables_ and _foreign tables_ (`relkind IN ('r','v','m','p','f')`).
In the example below a response contains Rails system tables (`schema_migrations` и
`ar_internal_metadata`) and two application specific tables - `accounts` and
`payments`:

```
       relname
----------------------
 schema_migrations
 ar_internal_metadata
 accounts
 payments
(4 rows)
```

- <https://www.postgresql.org/docs/12/catalog-pg-class.html>
- <https://www.postgresql.org/docs/9.2/catalog-pg-namespace.html>


### #7

```sql
SELECT a.attname
  FROM (
         SELECT indrelid, indkey, generate_subscripts(indkey, 1) idx
           FROM pg_index
          WHERE indrelid = '"accounts"'::regclass
            AND indisprimary
       ) i
  JOIN pg_attribute a
    ON a.attrelid = i.indrelid
   AND a.attnum = i.indkey[i.idx]
 ORDER BY i.idx
```

Rails obtains a primary key name of the `accounts` table, that contains all the accounts and needed to execute the original user request `Account.last`:

```
 attname
---------
 id
(1 row)
```

- <https://www.postgresql.org/docs/12/catalog-pg-index.html>
- <https://www.postgresql.org/docs/12/catalog-pg-attribute.html>


### #8

```sql
SHOW search_path
```

PostgreSQL provides conception of a database schema. A database contains multiple schemas and each schema contains tables and other names entities. Basicaly it's a namespace.
The full indentifier of a table consists of database name, a schema and a table, e.g. `my_database.my_schema.my_table`. If in a SQL query a table name is used without schema name then the table is being searched in schemas listed in a `search_path` list.

The option `search_path` by default has the following value `"$user", public`, where `"$user"` means a name of a a current user and is ignored in case such schema doesn't exist. So usually the `public` is used.

```
   search_path
-----------------
 "$user", public
(1 row)
```

<https://www.postgresql.org/docs/12/ddl-schemas.html>


### #9

```sql
SELECT a.attname, format_type(a.atttypid, a.atttypmod),
       pg_get_expr(d.adbin, d.adrelid), a.attnotnull, a.atttypid, a.atttypmod,
       c.collname, col_description(a.attrelid, a.attnum) AS comment
  FROM pg_attribute a
  LEFT JOIN pg_attrdef d ON a.attrelid = d.adrelid AND a.attnum = d.adnum
  LEFT JOIN pg_type t ON a.atttypid = t.oid
  LEFT JOIN pg_collation c ON a.attcollation = c.oid AND a.attcollation <> t.typcollation
 WHERE a.attrelid = '"accounts"'::regclass
   AND a.attnum > 0 AND NOT a.attisdropped
 ORDER BY a.attnum
```

This way Rails obtains the table `accounts` structure - column names (`id`,
`name`), types, `NOT NULL` constraints, etc:

```
 attname |    format_type    |             pg_get_expr              | attnotnull | atttypid | atttypmod | collname | comment
---------+-------------------+--------------------------------------+------------+----------+-----------+----------+---------
 id      | bigint            | nextval('accounts_id_seq'::regclass) | t          |       20 |        -1 |          |
 name    | character varying |                                      | f          |     1043 |        -1 |          |
(2 rows)
```

The column `atttypid` contains type identifiers, that were fetched on the
step #5:

```
  oid  |        typname        | typelem | typdelim |    typinput    | rngsubtype | typtype | typbasetype
-------+-----------------------+---------+----------+----------------+------------+---------+-------------
    20 | int8                  |       0 | ,        | int8in         |            | b       |           0
  1043 | varchar               |       0 | ,        | varcharin      |            | b       |           0
```

The column `atttypmod` contains type-specific attributes, that were specified for a column at a table creation, e.g. length of _varchar_. Value -1 means, that there are no an attributes.

The condition `a.attnum > 0` means that hidden system columns are filtered out and only columns specified explicitly by a user during a table creation or structure modification are fetched. For system columns, e.g. `oid`, `attrnum` is negative.

There is another condition - `NOT a.attisdropped`. The column
`attisdropped` contains a flag that means a column is deleted. Dispite a
column is deleted phisically column values are still stored in a table but are
ignored during SQL queries execution.

- <https://www.postgresql.org/docs/12/catalog-pg-attribute.html>
- <https://www.postgresql.org/docs/12/catalog-pg-attrdef.html>
- <https://www.postgresql.org/docs/12/catalog-pg-type.html>
- <https://www.postgresql.org/docs/12/catalog-pg-collation.html>


### #10

```sql
SHOW max_identifier_length
```

The `max_identifier_length` option is read-only and contains the maximum
length of table and column names. It's initialized on the Postgres compilation step and by default is 63 bytes.

```
 max_identifier_length
-----------------------
 63
(1 row)
```

<https://www.postgresql.org/docs/10/runtime-config-preset.html#GUC-MAX-IDENTIFIER-LENGTH>


### Table specific SQL queries

As we have seen, some queries are generic and related to connection
setup and a database settings. All the other queries are related to the
`accounts` table, which is used to execute the original user request.

If to execute similar Ruby expression that involves another table (`payments`),

```
Payment.last
SELECT  "payments".* FROM "payments" ORDER BY "payments"."id" DESC LIMIT $1
```

then we will see only `payments` table specific queries - fetching a
primary key name and the table structure:

```sql
SELECT a.attname
  FROM (
         SELECT indrelid, indkey, generate_subscripts(indkey, 1) idx
           FROM pg_index
          WHERE indrelid = '"payments"'::regclass
            AND indisprimary
       ) i
  JOIN pg_attribute a
    ON a.attrelid = i.indrelid
   AND a.attnum = i.indkey[i.idx]
 ORDER BY i.idx

SELECT  "payments".* FROM "payments" ORDER BY "payments"."id" DESC LIMIT $1

SELECT a.attname, format_type(a.atttypid, a.atttypmod),
       pg_get_expr(d.adbin, d.adrelid), a.attnotnull, a.atttypid, a.atttypmod,
       c.collname, col_description(a.attrelid, a.attnum) AS comment
  FROM pg_attribute a
  LEFT JOIN pg_attrdef d ON a.attrelid = d.adrelid AND a.attnum = d.adnum
  LEFT JOIN pg_type t ON a.atttypid = t.oid
  LEFT JOIN pg_collation c ON a.attcollation = c.oid AND a.attcollation <> t.typcollation
 WHERE a.attrelid = '"payments"'::regclass
   AND a.attnum > 0 AND NOT a.attisdropped
 ORDER BY a.attnum
```

If we execute the Ruby expression one more time then only the query to fetch rows from the table will be executed.


### How to make the hidden queries visible

One of the simplest ways to see system SQL queries made by Rails, but
not the most transparent, it's a built in Rails mechanism of
notifications.

Rails publishes events for all the meaningful operations:
- calling a controller *action*,
- rendering of a view or a *partial*
- executing SQL queries
- ...

So for every system or user-initiated SQL query a corresponding event will be published.

To see hidden SQL queris you need just to launch Rails console and subscribe on `sql.active_record` events in the following way:

```ruby
ActiveSupport::Notifications.subscribe "sql.active_record" do |name, started, finished, unique_id, data|
  puts "#{data[:sql]}\n"
end
```

And then every SQL query will be printed into console.

- <https://guides.rubyonrails.org/active_support_instrumentation.html>
- <https://api.rubyonrails.org/classes/ActiveSupport/Notifications.html>


### Links

- <https://api.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/PostgreSQLAdapter.html>
- <https://github.com/rails/rails/blob/5-2-stable/activerecord/lib/active_record/connection_adapters/postgresql_adapter.rb>
- <https://github.com/rails/rails/blob/5-2-stable/activerecord/lib/active_record/connection_adapters/postgresql/schema_statements.rb>


[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
