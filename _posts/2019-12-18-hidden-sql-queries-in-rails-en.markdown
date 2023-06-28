---
layout:     post
title:      "Hidden SQL queries in Rails"
date:       2019-12-18 00:43
categories: Rails
extra_head: |
  <style>
    pre code { white-space: pre; }
  </style>
---

Imagine the sequence of events when we run Rails console and
execute our first SQL query against the PostgreSQL database:

```ruby
Account.last
#  Account Load (1.9ms)  SELECT  "accounts".* FROM "accounts" ORDER BY "accounts"."id" DESC LIMIT $1  [["LIMIT", 1]]
```

Rails constructs an SQL query, logs and sends it to the database for
execution. These SQL queries flood the console output and development
log files, representing the visible interaction between Rails and the
database. However, there are also concealed SQL queries that Rails
executes behind the scenes.

### Establishing a New Connection

Consider the environment of Rails 5.2 in conjunction with PostgreSQL 12.
If you run Rails console and execute `Account.last` expression, Rails
unexpectedly executes multiple SQL queries:

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

Let's determine what is happening.

Rails establishes a connection to the database lazily, meaning it only
does so when necessary, for instance when the first SQL query to the
database is made. Hence, prior to executing `Account.last`, Rails has
not established any connection to database.

When the `last` method is invoked, Rails not only establishes but also sets up and configure a  connection to the database. In order to generate _accessors_ for model attributes and correctly type-cast attribute values based on table column types, Rails requires knowledge of the table schema. This information is lazily loaded from the database during the first execution of an SQL query and subsequently cached.

Let's now examine each of the SQL queries mentioned above in detail.


### #1

```sql
SET client_min_messages TO 'warning'
```

Rails configures the `client_min_messages` option, which determines the
level of client logging (set to `warning` in our case). The PostgreSQL
server logs both system and user messages based on the specified logging
level. These messages can include the resulting parse tree, the query
rewriter output, or the execution plan for each executed SQL query. The
decision to persist these messages is contingent upon the
connection-specific client logging level, which, by default, is set to
`notice`.

For some experimentation, you can have fun by tinkering with the
Postgres debug output. Set the logging level to the most detailed option
(`DEBUG1`) and enable logging. This allows you to observe various
details, such as execution plans and the internal representation of SQL
queries both before and after optimization:

```sql
SET debug_print_plan      TO true;
SET debug_print_rewritten TO true;
SET debug_print_parse     TO true;

SET client_min_messages   TO 'DEBUG1';

SELECT * FROM accounts;               -- or any other SQL query
```

The realm of debug output in PostgreSQL is an expansive subject that
merits an entire post dedicated to its intricacies. Nonetheless, here
are a few notable links worth mentioning for deeper insights:

- <https://www.postgresql.org/docs/12/runtime-config-client.html#GUC-CLIENT-MIN-MESSAGES>
- <https://www.postgresql.org/docs/12/runtime-config-logging.html#RUNTIME-CONFIG-SEVERITY-LEVELS>


### #2

```sql
SET standard_conforming_strings = on
```

The `standard_conforming_strings` option alters the interpretation of
string literals within SQL queries, specifically affecting the handling
of backslash sequences (`\n`, `\t`, and so on). When this option is
enabled, the interpretation of these sequences is disabled. Starting
from PostgreSQL 9.1, this option is enabled by default.

Links:
- <https://www.postgresql.org/docs/12/runtime-config-compatible.html#GUC-STANDARD-CONFORMING-STRINGS>
- <https://www.postgresql.org/docs/12/sql-syntax-lexical.html#SQL-SYNTAX-STRINGS-ESCAPE>


### #3

```sql
SET SESSION timezone TO 'UTC'
```

This command explicitly sets the timezone for a connection. The
connection's timezone is utilized in the following scenarios:
- when transmitting data from a database server, time values with a timezone are converted to match the connection's timezone.
- when transmitting data to a database server, time literals without an explicit timezone are assigned the connection's timezone.

If the timezone is not explicitly set, the following rules come into play:
- on the client side, if the environment variable `PGTZ` is set, the
*libpq* client library will utilize it to establish the connection
timezone automatically
- if `PGTZ` isn't set, PostgreSQL on the server side will check if the
timezone is configured in the `postgresql.conf` file
- if the timezone isn't configured, the server will resort to the
server's local timezone:
  - the `TZ` environment variable is checked
  - and only then the system's local timezone is used.

Links:
- <https://www.postgresql.org/docs/12/runtime-config-client.html#GUC-TIMEZONE>
- <https://www.postgresql.org/docs/12/datatype-datetime.html#DATATYPE-TIMEZONES>


### #4

```sql
SELECT t.oid, t.typname
FROM pg_type as t
WHERE t.typname IN ('int2', 'int4', 'int8', 'oid', 'float4', 'float8', 'bool')
```

In this manner, Rails acquires information about certain basic types within PostgreSQL. The `pg_type` system table houses attributes of both built-in and custom user types. Rails retrieves the type name and the primary key *oid* from this table:

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

In this manner, Rails acquires the attributes of built-in PostgreSQL
types (`t.typname IN ('int2', 'float4', 'text', 'varchar', ...)`) as
well as user-defined custom types such as *ranges*, *enums*, *domains*
(`t.typtype IN ('r', 'e', 'd')`), and *arrays* (`t.typelem != 0`).

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

Rails retrieves comprehensive list of tables, *views*, *materialized
views*, *partitioned tables*, and *foreign tables* (`relkind IN ('r',
'v', 'm', 'p', 'f')`). Illustratively, in the provided example, the
response comprises not only Rails system tables (`schema_migrations` and
`ar_internal_metadata`) but also two tables specific to the application:
`accounts` and `payments`:

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

In this manner, Rails retrieves the primary key name of the `accounts` table.

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

PostgreSQL introduces the concept of a database schema, where a database
can consist of multiple schemas, each containing tables and other named
entities. Essentially, a schema acts as a namespace. The complete
identifier of a table comprises the database name, schema name, and
table name, such as `my_database.my_schema.my_table`. When a table name
is used in a SQL query without specifying the schema, PostgreSQL
searches for the table within the schemas listed in the `search_path`
option.

By default, the `search_path` option is set to `"$user", public`, where
`"$user"` represents the name of the current user and is ignored if such
a schema doesn't exist. Therefore, the `public` schema is typically
utilized.

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

In this manner, Rails acquires the structure of the accounts table,
including the column names (`id`, `name`), data types, *NOT NULL*
constraints, and more:

```
 attname |    format_type    |             pg_get_expr              | attnotnull | atttypid | atttypmod | collname | comment
---------+-------------------+--------------------------------------+------------+----------+-----------+----------+---------
 id      | bigint            | nextval('accounts_id_seq'::regclass) | t          |       20 |        -1 |          |
 name    | character varying |                                      | f          |     1043 |        -1 |          |
(2 rows)
```

The `atttypid` column stores the type identifiers that were retrieved
during step #5:

```
  oid  |        typname        | typelem | typdelim |    typinput    | rngsubtype | typtype | typbasetype
-------+-----------------------+---------+----------+----------------+------------+---------+-------------
    20 | int8                  |       0 | ,        | int8in         |            | b       |           0
  1043 | varchar               |       0 | ,        | varcharin      |            | b       |           0
```

The `atttypmod` column stores type-specific attributes that were
specified for a column during table creation, such as the length of a
*varchar* column. A value of -1 indicates the absence of attributes.

The condition `a.attnum > 0` filters out hidden system columns, ensuring
that only columns explicitly specified by a user during table creation
or structure modification are retrieved. System columns, such as `oid`,
have negative attnum values.

Another condition, `NOT a.attisdropped`, is applied. The `attisdropped`
column contains a flag that indicates whether a column has been deleted.
Despite the deletion of a column, its values are still physically stored
in the table but are ignored during the execution of SQL queries.

- <https://www.postgresql.org/docs/12/catalog-pg-attribute.html>
- <https://www.postgresql.org/docs/12/catalog-pg-attrdef.html>
- <https://www.postgresql.org/docs/12/catalog-pg-type.html>
- <https://www.postgresql.org/docs/12/catalog-pg-collation.html>


### #10

```sql
SHOW max_identifier_length
```

The `max_identifier_length` option is a read-only setting that specifies
the maximum length allowed for table and column names. It is set during
the compilation of PostgreSQL and has a default value of 63 bytes.

```
 max_identifier_length
-----------------------
 63
(1 row)
```

<https://www.postgresql.org/docs/10/runtime-config-preset.html#GUC-MAX-IDENTIFIER-LENGTH>


### Table Specific SQL Queries

As observed, there are generic queries associated with connection setup
and database settings. Additionally, there are queries specifically
related to the `accounts` table, which is utilized to fulfill the original
user request.

If we were to execute a similar Ruby expression involving another table,
such as `payments`,

```
Payment.last
SELECT  "payments".* FROM "payments" ORDER BY "payments"."id" DESC LIMIT $1
```

then we would observe queries specific to the `payments` table, such as
fetching the primary key name and the table structure:

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

Upon executing the Ruby expression once more, only the query to retrieve
rows from the table will be executed.


### Making Hidden Queries Visible

One straightforward approach to view the system SQL queries performed by
Rails, albeit not the most transparent one, is through the use of Rails'
built-in notification mechanism.

Rails emits events for various significant operations, including:
- calling a controller *action*,
- rendering of a view or a *partial*
- executing SQL queries
- ...

Hence, a corresponding event will be published for every SQL query
initiated by Rails or the user.

To make hidden SQL queries visible, all you need to do is to run Rails
console and subscribe to `sql.active_record` events using the following
approach:

```ruby
ActiveSupport::Notifications.subscribe "sql.active_record" do |name, started, finished, unique_id, data|
  puts "#{data[:sql]}\n"
end
```

As a result, each SQL query will be displayed in the console.

- <https://guides.rubyonrails.org/active_support_instrumentation.html>
- <https://api.rubyonrails.org/classes/ActiveSupport/Notifications.html>


### Links

- <https://api.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/PostgreSQLAdapter.html>
- <https://github.com/rails/rails/blob/5-2-stable/activerecord/lib/active_record/connection_adapters/postgresql_adapter.rb>
- <https://github.com/rails/rails/blob/5-2-stable/activerecord/lib/active_record/connection_adapters/postgresql/schema_statements.rb>


[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
