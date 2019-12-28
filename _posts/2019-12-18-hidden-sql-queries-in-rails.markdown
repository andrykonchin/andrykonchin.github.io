---
layout:     post
title:      "Невидимые SQL-запросы в Rails"
date:       2019-12-18 00:43
categories: Rails
extra_head: |
  <style>
    pre code { white-space: pre; }
  </style>
---

Давайте представим, что происходит, когда запускается Rails-консоль и
делается первый запрос к базе данных:

```
irb(main):001:0> Account.last
  Account Load (1.9ms)  SELECT  "accounts".* FROM "accounts" ORDER BY "accounts"."id" DESC LIMIT $1  [["LIMIT", 1]]
```

Rails формирует SQL-запрос, логирует и отдает на выполнение базе данных.
SQL-запросы постоянно мелькают перед глазами в логах и консоли. Но этим
взаимодействие Rails и базы данных не ограничивается. Давайте
подсмотрим, какие еще невидимые SQL-запросы выполняются в Rails.


### Установка нового соединения

Рассмотрим Rails 5.2 и PostgreSQL 12. Если зайти в Rails-консоль и
ввести `Account.last`, то Rails выполнит кучу странных SQL-запросов:

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

Давайте разберем что здесь к чему.

Rails устанавливает соединения с базой данных лениво, т.е. только при
необходимости, при первом обращении к базе. Поэтому до выполнения
`Account.last` Rails не установило ни одного соединения.

При вызове метода `last` Rails устанавливает и настраивает первое
соединение к базе данных. Чтобы сгенерировать _accessor_'ы для атрибутов
моделей и выполнять _type casting_ атрибутов к типам колонок Rails нужна
структура таблиц. Эти данные лениво загружаются из базы при первом
обращении к таблице и, конечно же, кэшируются.

Давайте разберем каждый из приведенных выше SQL-запросов.


### #1

```sql
SET client_min_messages TO 'warning'
```

Rails настраивает `client_min_messages` - уровень клиентского
логирования (`warning` в данном случае). Сервер базы данных логирует
служебные и пользовательские сообщения в журнал согласно серверному
уровню логировани - например вывод дерева запроса, дерево запроса после
применения правил или плана выполнения. Решение отправлять ли эти
сообщению клиенту зависит от выставленного для соединения уровня
клиентского логирования, который по-умолчанию равен `notice`.

Ради интереса можно поиграться с отладочным выводом PostgreSQL. Для
этого надо выставить самый подробный уровень логирования (`DEBUG1`) и
включить логирование, на пример, плана запросов или внутреннего
представления SQL-запросов до и после оптимизации:

```sql
SET debug_print_plan      TO true;
SET debug_print_rewritten TO true;
SET debug_print_parse     TO true;

SET client_min_messages   TO 'DEBUG1';

SELECT * FROM accounts;               -- или любой другой SQL-запрос
```

Отладочный вывод в PostgreSQL это большая и интересная тема и
заслуживает отдельный пост.

- <https://www.postgresql.org/docs/12/runtime-config-client.html#GUC-CLIENT-MIN-MESSAGES>
- <https://www.postgresql.org/docs/12/runtime-config-logging.html#RUNTIME-CONFIG-SEVERITY-LEVELS>


### #2

```sql
SET standard_conforming_strings = on
```

Опция `standard_conforming_strings` влияет на интерпретацию строковых
литералов в запросах - точнее на интерпретацию
*backslash*-последовательностей (`\n`, `\t`, ...). Включенная опция
означает, что интерпретация будет выключена. Начиная с PostgreSQL 9.1
опция включена по-умолчанию.

- <https://www.postgresql.org/docs/12/runtime-config-compatible.html#GUC-STANDARD-CONFORMING-STRINGS>
- <https://www.postgresql.org/docs/12/sql-syntax-lexical.html#SQL-SYNTAX-STRINGS-ESCAPE>


### #3

```sql
SET SESSION timezone TO 'UTC'
```

Эта команда, что впрочем очевидно, выставляет _timezone_ для соединения.
База данных использует _timezone_ в следующих случаях:
- при передаче данных клиенту даты и время с _timezone_ конвертируется в
  системный _timezone_
- при передаче данных серверу литералы даты и времени без явного
  _timezone_ неявно получает системный _timezone_

Если _timezone_ не указать явно, то работают следующие правила:
- если выставить на клиенте переменную окружения `PGTZ`, то клиентская
  библиотека `libpq` самостоятельно выставит этот _timezone_ для
  соединений
- если клиент не выставил _timezone_ для соединения, то PostgreSQL
  проверит выставлен ли _timezone_ в конфиге `postgresql.conf`
- если и там _timezone_ не настроен, тогда используется локальный
  _timezone_ сервера:
  - PostgreSQL смотрит в переменную окружения `TZ` и только затем
  - получает текущий _timezone_ у операционной системы


Ссылки:
- <https://www.postgresql.org/docs/12/runtime-config-client.html#GUC-TIMEZONE>
- <https://www.postgresql.org/docs/12/datatype-datetime.html#DATATYPE-TIMEZONES>


### #4

```sql
SELECT t.oid, t.typname
FROM pg_type as t
WHERE t.typname IN ('int2', 'int4', 'int8', 'oid', 'float4', 'float8', 'bool')
```

Здесь Rails получает информацию о некоторых базовых типах PostgreSQL. В
служебной таблице `pg_type`, хранятся характеристики базовых и
пользовательских типов. Rails зачитывает имя типа и первичный ключ
`oid`:

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

Здесь Rails зачитывает характеристики как базовых типов (`t.typname IN
('int2', 'float4', 'text', 'varchar'...)`), так и пользовательских -
_ranges_, _enums_ и _domains_ (`t.typtype IN ('r', 'e', 'd')`) и
массивов (`t.typelem != 0`).

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

Rails получает список таблиц, _views_, _materialized_ _views_,
_partitioned tables_ и _foreign tables_ (`relkind IN ('r','v','m','p','f')`).
В примере возвращаются служебные таблицы Rails (`schema_migrations` и
`ar_internal_metadata`) и две пользовательские таблицы - `accounts` и
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

Rails получает имя первичного ключа таблицы `accounts` к которой
обращались в изначальном запросе:

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

PostgreSQL поддерживает понятие схема базы. База данных содержит схемы,
а те в свою очередь содержат таблицы и другие именованные объекты.
Полный идентификатор таблицы состоит из имени базы, схемы и имени
таблицы - `my_database.my_schema.my_table`. Если в запросе используют
имя таблицы без схема, она ищется в перечисленных в `search_path`
схемах.

Опция `search_path` по-умолчанию равна `"$user", public`, где `"$user"`
означает имя текущего пользователя и игнорируется если такой схемы нет.
Поэтому обычно применяется схема `public`.

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

Здесь Rails получает структуру таблицы `accounts` - имена полей (`id`,
`name`), типы, `NOT NULL` ограничения, etc:

```
 attname |    format_type    |             pg_get_expr              | attnotnull | atttypid | atttypmod | collname | comment
---------+-------------------+--------------------------------------+------------+----------+-----------+----------+---------
 id      | bigint            | nextval('accounts_id_seq'::regclass) | t          |       20 |        -1 |          |
 name    | character varying |                                      | f          |     1043 |        -1 |          |
(2 rows)
```

В колонке `atttypid` возвращаются id типов, которые получили на шаге #5:

```
  oid  |        typname        | typelem | typdelim |    typinput    | rngsubtype | typtype | typbasetype
-------+-----------------------+---------+----------+----------------+------------+---------+-------------
    20 | int8                  |       0 | ,        | int8in         |            | b       |           0
  1043 | varchar               |       0 | ,        | varcharin      |            | b       |           0
```

В поле `atttypmod` хранится специфичные для типа параметры, которые
указывались для колонки при создании таблицы, например, максимальная
длина для _varchar_. Значение -1 означает, что таких данных нет.

Условие `a.attnum > 0` означает, что загружаются только пользовательские
колонки, которые указали при создании или изменении структуры таблицы.
Для служебных колонок, например `oid`, значение `attrnum` отрицательное.

Колонки фильтруются по еще одному условию - `NOT a.attisdropped`. В поле
`attisdropped` хранится признак, что колонку удалили из таблицы.
Несмотря на удаление колонки данные остаются в таблице но игнорируются
при выполнении SQL-запросов.

- <https://www.postgresql.org/docs/12/catalog-pg-attribute.html>
- <https://www.postgresql.org/docs/12/catalog-pg-attrdef.html>
- <https://www.postgresql.org/docs/12/catalog-pg-type.html>
- <https://www.postgresql.org/docs/12/catalog-pg-collation.html>


### #10

```sql
SHOW max_identifier_length
```

`max_identifier_length` - это _read-only_ значение, которое ограничивает
длину имен таблиц и колонок. Опция задается только на этапе компиляции
PostgreSQL и по-умолчанию равно 63 байтам.

```
 max_identifier_length
-----------------------
 63
(1 row)
```

<https://www.postgresql.org/docs/10/runtime-config-preset.html#GUC-MAX-IDENTIFIER-LENGTH>


### SQL-запросы для таблиц

Как видно, часть запросов общие и относятся к клиентским настройкам
соединения и настройкам самой базы данных. Остальные запросы касаются
таблицы `accounts`, к которой обращались в изначальном запросе.

Если тут же сделать аналогичный запрос к другой таблице (`payments`),

```
irb(main):002:0> Payment.last
SELECT  "payments".* FROM "payments" ORDER BY "payments"."id" DESC LIMIT $1
```

то увидим только специфичные для нее запросы - определение первичного
ключа и схемы таблицы:

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

Если повторить этот же запрос еще раз, выполнится только запрос на
чтение данных из таблицы `payments` и служебные запросы уже не делаются.


### Как сделать невидимые запросы видимыми

Один из самых доступных способов увидеть служебные SQL-запросы, хотя и
не самый прозрачный, это встроенный в Rails механизм событий.

В Rails события публикуются для всех основных операций: вызовы
*action*'ов *controller*'а, рендеринг *partial*'ов и шаблонов,
выполнение SQL-запросов итд. В последнем случае события будут
публиковаться для каждого SQL-запроса, как пользовательского так и
служебного.

Чтобы увидеть служебные запросы достаточно зайти в Rails-консоль и
подписаться на событие `sql.active_record` следующим образом:

```ruby
ActiveSupport::Notifications.subscribe "sql.active_record" do |name, started, finished, unique_id, data|
  puts "#{data[:sql]}\n"
end
```

Далее любой невидимый SQL-запрос будет выводиться в консоль.

- <https://guides.rubyonrails.org/active_support_instrumentation.html>
- <https://api.rubyonrails.org/classes/ActiveSupport/Notifications.html>


### Ссылки

- <https://api.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/PostgreSQLAdapter.html>
- <https://github.com/rails/rails/blob/5-2-stable/activerecord/lib/active_record/connection_adapters/postgresql_adapter.rb>
- <https://github.com/rails/rails/blob/5-2-stable/activerecord/lib/active_record/connection_adapters/postgresql/schema_statements.rb>


[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
