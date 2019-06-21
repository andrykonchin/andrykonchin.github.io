---
layout: post
title:  "Алгоритмы в Unicorn"
date:   2019-06-22 00:37
categories: Ruby
---

Unicorn это один из самых популярных веб-серверов для Ruby. Если кратко, то это Rack-совместимый классический _fre-fork_ веб-сервер.


<img src="/assets/images/2019-06-22-algorithms-in-unicorn/unicorn.jpg" style="width: 20em; margin-left: auto; margin-right: auto;" />

Он следует принципу "Do one thing, do it well” и поэтому не умеет HTTP _pipelining_, _keep-alive_ и не предназначен для обработки медленных клиентов. Кроме того, он поддерживает только Unix системы.

Я начал разбиратсья с Unicorn просто из любопытства и неожиданно погрузился в тонкости программирования под Unix. Unicorn интенсивно использует системные вызовы для работы с процессами и IPC. Также было интересно разбираться, как это все доступно в Ruby.

В этой статье мы разберем по шагам как Unicorn работает изнутри, как организовано управление процессами, как обрабатываются входящие HTTP запроса и все то, что не прочитаешь в документации.



### Запуск Unicorn

```
parse command line options
if passed "-D" or "—daemonize" command line option
    daemonize
start HTTP server
```
[source](https://github.com/defunkt/unicorn/blob/v5.5.1/bin/unicorn)

Unicorn запускается консольной командой `unicorn` из директории приложения. Поддерживается совместимость с опциями таких команд как `ruby` и `rackup` (из _gem_’а Rack).

Unicorn поддерживает следующие опции командной строки:

Ruby опции:
<pre>
"-e", "--eval LINE", "evaluate a LINE of code"
"-d", "--debug", "set debugging flags (set $DEBUG to true)"
"-w", "--warn", "turn warnings on for your script"
"-I", "--include PATH",
          "specify $LOAD_PATH (may be used more than once)"
"-r", "--require LIBRARY",
          "require the library, before executing your script"
</pre>

Опции для совместимости с `rackup`:
<pre>
"-o", "--host HOST",
          "listen on HOST (default: 0.0.0.0)"
"-p", "--port PORT", Integer,
          "use PORT (default: 8080)"
"-E", "--env RACK_ENV",
          "use RACK_ENV for defaults (default: development)"
"-N", "--no-default-middleware",
          "do not load middleware implied by RACK_ENV"
"-D", "--daemonize", "run daemonized in the background"
"-s", "--server SERVER",
          "this flag only exists for compatibility"
</pre>

Unicorn-специфичные опции:
<pre>
"-l", "--listen {HOST:PORT|PATH}"
          "listen on HOST:PORT or PATH",
          "this may be specified multiple times",
          "(default: 0.0.0.0:8000)")
"-c", "--config-file FILE", "Unicorn-specific config file"
</pre>

В Unicorn намеренно избегают конфигурацию через опции командной строки в пользу конфигурационного файла, который обычно кладут в `config/unicorn.rb`. Это упрощает код так как в этом случае есть только один источник конфигурации вместо двух.

Любопытна опция `—eval`. Фактически это означает:

```ruby
eval line, TOPLEVEL_BINDING, "-e", lineno
```

`--debug` опция как и написано выше выставляет стандартную глобальную переменную `$DEBUG` в `true`. Это означает, что любое исключение будет прологировано в `STDERR` (но без _backtrace_).

`--warn` выставляет стандартную глобальную переменную `$VERBOSE` в `true`. Это включает вывод _warning_'ов самого Ruby.

`--include` принимает путь к директории, которое будет добавлено в `$LOAD_PATH`. Можно передать несколько путей, если разделить их ':'.

`rack` _gem_ включает в себя несколько стандартных Rack _middleware_ и по-умолчанию они добавляются в стек: `ContentLength`, `Chunked`, `CommonLogger`, `ShowExceptions`, `Lint`, `TempfileReaper`. Опция `--no-default-middleware` означает, что Unicorn не будет их добавлять.

`--daemonize` опция означает запуск веб-сервера в виде демона. Процесс будет откреплен от текущего терминала и будет выполняться в фоне.

`--server` опция - просто заглушка и приводит только в выводу предупреждения в `STDOUT`.

Ссылки:
* [Rackup опции (source)](https://github.com/rack/rack/blob/master/lib/rack/server.rb)
* [Unicorn опции (source)](https://github.com/defunkt/unicorn/blob/v5.5.1/bin/unicorn#L11-L112)
* [Документация по конфигурации Unicorn](https://bogomips.org/unicorn/Unicorn/Configurator.html)
* [Документация Ruby по стандартным глобальным переменных](https://docs.ruby-lang.org/en/2.6.0/globals_rdoc.html)



### Демонизация

```
# grandparent process:

open pair of Unix pipes
fork
wait for incoming data in Unix-pipe

if pipe closed unexpectedly
    exit 1
exit 0
```

```
# parent process:

setsid
fork
exit
```
[source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/launcher.rb#L13-L60)

Здесь происходит следующее. Процесс, запущенный в консоле (_grandparent_), открывает _Unix pipe_ для общения с дочерними процессами. Далее он создает дочерний процесс делая системный вызов [`fork`](http://man7.org/linux/man-pages/man2/fork.2.html) и засыпает ожидая входящих данных в _pipe_'е. Любое сообщение в нем будет означать, что веб-сервера в дочернем процессе успешно запустился. Получив это уведомление _grandparent_ процесс успешно завершается.

Если _master_ процесс (внук) не смог стартовать веб-сервер и неуспешно завершился, то _pipe_ закрывается операционной системой и в него шлется признак _EOF_ (_End Of File_). _Grandparent_ понимает, что _master_ процесс завершился с ошибкой, выводит об этом сообщение в _STDOUT_ и сам завершается.

Дочерний (_parent_) процесс выполняет только одно действие - делает системный вызов [`setsid`](https://linux.die.net/man/2/setsid). Как следствие создается новая сессия процессов, в ней создается новая группа процессов и _parent_ процесс становится лидером как сессии так и группы. Все дочерние процессы (как _master_ так и _worker_'ы) будут входить в эту группу и сессию.

Далее _parent_ процесс создает дочерний _master_ процесс и завершается.

Ссылки:
* [The Linux kernel. Andries Brouwer. Processes](https://www.win.tue.nl/~aeb/linux/lk/lk-10.html)
* [Process group (Wikipedia)](https://en.wikipedia.org/wiki/Process_group)



### Запуск HTTP сервера

```
save start context
inherit listeners
open Unix pipe (self-pipe)
set up system signal handlers

write pid file

if configured to preload application
    load application from config.ru file

bind and listen to addresses
spawn worker processes
notify grandparent process about server starting successfully
monitor workers
```
[source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L121-L146)

При запуске веб-сервера из консоли вначале сохраняется сама это команда и ее параметры (начальный контекст). Сохраняются `$0` - путь к исполняемому файлу Unicorn, `ARGV` - параметры командной строки и `CWD` (_current working directory_) - путь к директории приложения, где был запущен Unicorn. Эти данные нужны позднее для перезапуска сервера. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L33-L64))

Далее активируются унаследование от старого _master_'а серверные сокеты, если происходит перезапуск веб-сервера (посылкой сигнала `USR2`).

Затем создается еще один _Unix-pipe_ (назовем его _self-pipe_, о нем будет подробнее чуть позже).

После этого регистрируются обработчики сигналов. Unicorn обрабатывает следующие сигналы: `WINCH`, `QUIT`, `INT`, `TERM`, `USR1`, `USR2`, `HUP`, `TTIN`, `TTOU` и `CHLD`.

В конфигурационном файле можно задать опцию `preload_app`. Это означает, что приложение будет загружено и инициализировано заранее в _master_ процессе, а процессы _worker_'ы получат уже загруженное приложение, готовое к обработке входящих запросов. Это делает запуск нового _worker_'а практически мгновенным. Если эта опция не выставлена, то каждый _worker_ будет загружать и инициализировать приложение независимо. Это никак не влияет на время запуска самого Unicorn'а, но будет вызывать дополнительную задержку при запуске нового _worker_'а на лету (сигнал TTIN) или при автоматичеком запуске _worker_'а взамен внезапно завершившимуся или убитому. В большом Rails приложении старт окружения может занимать 30-50 секунд, поэтому `preload_app` это _must have_ опция.

Еще одно преимущество предварительной загрузки приложения это экономия оперативной памяти в процессах _worker_'ах. Из-за механизма операционных систем _Copy-On-Write_ память занимаемая Ruby-приложением может разделяться между _worker_'ами и _master_'ом. В большом Rails приложении процесс _worker_'а может занимать до 1-1.5 Gb, поэтому экономия памяти будет очень заметной.

Загрузка самого приложение оборачивается в анонимную функцию (_lambda_) и выполняется либо в _master_ процессе либо в _worker_'ах. Для поддержки Rack DSL используется [`Rack::Builder`](https://github.com/rack/rack/blob/master/lib/rack/builder.rb) класс из Rack. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn.rb#L49-L94))

Для всех сконфигурированных адресов (кроме унаследованных от предыдущего _master_'а) открываются новые серверные сокеты. Задавая параметры `tries` и `delay` для каждого адреса независимо можно настроить повторные попытки открытия сокета, если адрес еще занят. По умолчанию будет 5 попыток с задержкой в 0.5 секунд. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L236-L263))

Далее _master_ создает процессы _worker_'ы, шлет сообщение в унаследованный от _grandparent_'а _pipe_, после чего тот завершается, и переходит в режим ожидания. В этом режиме _master_ обрабатывает входящие управляющие сигналы и мониторит состояние _worker_'ов.



#### Активация унаследованных сокетов

При перезапуске Unicorn используя связку системных вызовов `fork`+`exec` создает новый _master_ процесс, который наследует все файловые дескрипторы родительского процесса, в том числе и открытые сетевые сокеты. Хотя сами Ruby объекты сокетов при перезапуске конечно становятся недоступны (после системного вызова exec запускается новая RubyVM), но файловые дескрипторы все еще можно использовать. Файловые дескрипторы это по сути просто числа, номера из таблицы дескрипторов процесса, а после системного вызова `fork` дочерний процесс получает копию родительской таблицы файловых дескрипторов. Они называются файловыми, хотя могут указывать и на сокеты и на _pipe_'ы.

Учитывая это, чтобы избежать _downtime_'а, старый _master_ при перезапуске сохраняет дескрипторы открытых серверных сокетов (_aka_ слушающие сокеты) в переменную окружения `UNICORN_FD`, а новый _master_ их активирует, т.е. создает для этих дескрипторов новые Ruby объекты сокетов, и продолжает принимать входящие соединения по ним. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L808-L845))

Также Unicorn поддерживает интеграцию с systemd и активацию сокетов созданных внешним супервизором. Если настроить Unicorn как сервис в systemd и сконфигурировать активацию сокетов, то systemd будет создавать серверные сокеты заранее и при запуске Unicorn'а выставлять переменные окружения `LISTEN_PID` и `LISTEN_FDS`. Сконфигурированные серверные сокеты будут доступны в процессе Unicorn'а по дескрипторам начиная с 3 (0-2 уже заняты - `stdin`, `stdout` и `stderr`). В `LISTEN_FDS` передается число активированных сокетов, а в `LISTEN_PID` - PID процесса, которому предназначены эти дескрипторы. Так как переменная окружения может быть доступна в других дочерних процессах - важно активировать сокеты только в указанном процессе. Unicorn добавляет эти сокеты к другим, унаследованным при перезапуске сокетам от старого _master_'а (в случае если происходит перезапуск). Фактически Unicorn реализует функцию [sd_listen_fds(3)](https://manpages.debian.org/jessie/libsystemd-dev/sd_listen_fds.3.en.html). ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L813-L818))

Ссылки:
* [systemd for Developers I](http://0pointer.de/blog/projects/socket-activation.html)
* [Rethinking PID 1](http://0pointer.de/blog/projects/systemd.html)



#### Self-pipe трюк

_Self-pipe_ трюк это стандартный способ в Unix обрабатывать входящие сигналы процессов. [Сигналы](https://en.wikipedia.org/wiki/Signal_(IPC)) - это один из механизмов [IPC](https://en.wikipedia.org/wiki/Inter-process_communication) (Inter-process communication). Процесс может зарегистрировать обработчик конкретного сигнала и он будет вызываться каждый раз, когда этому процессу отправят соответствующий сигнал.

Трюк заключается в следующем. Процесс открывает _Unix pipe_ (_self-pipe_), регистрирует обработчики сигналов и блокирующе ждет данные в этом _pipe_. Обработчики сигналов не содержат никакой логики и просто пишут в этот _pipe_ сообщение о пришедшем сигнале, чтобы разбудить ждущий основной поток выполнения процесса ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L393-L396), [source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L132-L133))). Прочитав событие из _pipe_'а процесс синхронно обрабатывает его и снова ждет новых событий.

Такой подход призван решить проблему связанную с обработкой сигналов - проблему _re-entrancy_. Когда процессу приходит сигнал, он прерывает выполнение и в одноим из его потоков (в любом произвольном на самом деле) выполняется обработчик этого сигнала (стандартный или переопределенный). Код приложение может быть прерван в любом месте - может быть прерван системный вызов (и это может привести к его завершению с ошибкой `EINT`), может быть прерван другой обработчик сигнала и даже этот же самый обработчик, если сигнал был послан несколько раз подряд и обработка предыдущего сигнала еще не успела завершиться. Поэтому код обработчика должен обладать свойством reentrancy, т.е. может быть безопасно прерван самим собой.

Именно поэтому обработчики сигналов здесь не содержат системных вызовов и выполняются максимально быстро - идентификатор сигнала дописывается в Ruby массив для отложенной обработки. Операция добавления элемента в массив в Ruby не атомарная, но здесь похоже этим пренебрегают. Теоретически элемент массива может быть перезаписан параллельной операцией и потеряться.

Даже системные вызовы делятся на группы по этому признаку на _reentrant_ и не- _reentrant_.

Ссылки:
* [The self-pipe trick](https://cr.yp.to/docs/selfpipe.html)
* [The Self-Pipe Trick Explained](https://www.sitepoint.com/the-self-pipe-trick-explained)
* [Use reentrant functions for safer signal handling](https://www.ibm.com/developerworks/library/l-reent/index.html)
* [Linux Programmer's Manual. SIGNAL-SAFETY(7)](http://man7.org/linux/man-pages/man7/signal-safety.7.html)
* [Reentrancy (Wikipedia)](https://en.wikipedia.org/wiki/Reentrancy_(computing)#Reentrant_interrupt_handler)



### Запуск процессов worker'ов

```
# master process:

until all workers are created
    choose next worker id (index number)
    open pair of Unix pipes
    call before_fork hook

    spawn or fork new process
```

```
# worker process:

seed OpenSSL PRNG
set up new handlers for :QUIT, :TERM, :INT signals - exit
set up handler for USR1 - reopen log files
restore default system handler for :CHLD signal

if parent has received command to exit before forking worker but isn’t processed it
    exit 0

call after_fork hook

if configured new user
    change process owner user

if not (configured to preload application)
    load application from config.ru file

call after_worker_ready hook
set up handler for QUIT - close sockets and stop handling requests
start serving incoming connections
```
[source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L530-L558)

Unicorn запускает указанное в конфиге количество _worker_’ов (по умолчанию будет запущен только 1). Более того, можно изменять количество _worker_'ов динамически без перезапуска веб-сервера используя сигналы (`TTIN` - увеличить на 1, `TTOU` - уменьшить на 1). Процесс _worker_'а может завершиться сам или быть убитым _master_'ом если время обработки HTTP запроса превысило заданный _timeout_. В этом случае будет поднят новый процесс, чтобы сохранить заданное количество запущенных _worker_'ов.

Каждый _worker_ имеет свой уникальный номер. Он может быть повторно использован, если процесс был завершен и новому процессу присвоят наименьший свободный номер.

Далее создается пара _Unix-pipe_'ов. _master_ процесс и _worker_'ы могут общаться через них, ведь _worker_'ы наследуют все открытые дескрипторы. _master_ может управлять _worker_'ом через один из _pipe_'ов, а _worker_ в свою очередь может определить неожиданное завершение _master_ процесса по закрытию второго _pipe_'а.

Затем запускается `before_fork` _hook_ и _master_ создает дочерний процесс делая системный вызов `fork`. Это обычная схема, которая работает с `preload_app` режимом.

Не так давно был добавлен ([коммит](https://github.com/defunkt/unicorn/commit/ea1a4360d66a833d75fbd887388d8cd4fe4ae299)) другой механизм для запуска _worker_'ов - `fork` + `exec`. Очевидно, что будут накладные расходы на загрузку приложения, но таким образом усиливается безопасность. Новый процесс запускает независимую Ruby VM и не разделяет память с родительским процессов. Это мера направлена на борьбу с [_address space discovery attacks_](https://en.wikipedia.org/wiki/Address_space_layout_randomization).

Такой механизм включается опцией `worker_exec`. Новый процесс _worker_'а должен выполнить те же шаги, что и _master_ процесс при перезапуске - проанализировать конфигурацию, активировать унаследованные файловые дескрипторы и загрузить приложение. Так как _master_ процесс в этом случае не разделяет с _worker_'ом ни память ни таблицу файловых дескрипторов, то для передачи _worker_'у выбранного порядкового номера и двух _Unix pipe_'ов (для двунаправленного общения) используется переменная окружения `UNICORN_WORKER`, в которую через запятую сохраняются эти три числа. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L464-L478))

Далее запускается `after_hook`. В него передаются два объекта (_server_ и  _worker_), интерфейс которых стабилен и открыт. Это, например, позволяет для отладки добавить еще один серверный сокет, специфичный для конкретного _worker_'а, или запустить процесс под другим пользователем.

```ruby
# config/unicorn.rb
after_fork do |server, worker|
  # per-process listener ports for debugging/admin:
  server.listen "127.0.0.1:#{9293 + worker.nr}"
  worker.user 'andrew'
end
```

Если приложение сконфигурировано с `preload_app=true`, то в `after_fork` обычно переоткрывают сетевые соединения, которые были созданы при загрузке приложения (например, к базе данных, Redis, RabbitMQ итд), иначе они будут одновременно использоваться всеми _worker_'ами. К примеру до Rails 5 нужно было это явно делать для _pool_'а соединений к базе данных:

```ruby
before_fork do |server, worker|
  ActiveRecord::Base.connection.disconnect!
end

after_fork do |server, worker|
  ActiveRecord::Base.establish_connection
end
```

Unicorn, конечно, пытается бороться с утечкой файловых дескрипторов при перезапуске _master_'а - закрываются все файловые дескрипторы (кроме серверных сокетов) в диапазоне 3..1024, но при запуске _worker_'а это не делается.

Если задана конфигурационная опция `user`, то _worker_'ы будут запущены из под указанного пользователя (_master_ останется неизменным). Меняется _real_ и _effective_ _group ID_ и _real_ и _effective_ _user ID_ процессов. Также меняется _owner_ и _group_ лог-файлов. Фактически работает та же логика определения файлов, что и при перечитывании конфиг-файлов (при обработке `USR1` сигнала) - изменяются владелец и группа для всех открытых на запись/дозапись файлы в приложении. Любопытно, что для получения user id по username используется [`Etc.getgrnam`](https://ruby-doc.org/stdlib-2.6/libdoc/etc/rdoc/Etc.html#method-c-getpwnam) из StdLib - это Ruby интерфейс к конфигурационным файлам из `/etc` в Unix'ах.
([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/worker.rb#L112-L164))

Любопытно, что обработчик сигнала `QUIT` навешивается два раза. В первый раз при старте процесса обработчик просто завершит процесс. Но после загрузки приложения и вызова всех _hook_'ов и перед началом обработки входящих запросов обработчик выполнит "вежливую" остановку - закроет сокеты и дождется завершения текущих запросов и только затем процесс завершится.



### Режим ожидания master'а

```
until receive :QUIT or :TERM, :INT signals
    process any unhandled incoming signals
    reap all zombie worker processes
    kill timeouted workers
    stop excessive workers or spawn missing

    wait for incoming signals with timeout

stop workers gracefully
unlink PID file
```
[source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L265-L338)

Согласно [документации](https://bogomips.org/unicorn/SIGNALS.html) следующие сигналы приведут к завершению работы Unicorn’а:
`QUIT` - дождаться завершения обработки всех текущих HTTP запросов (_graceful shutdown_)
`TERM` и `INT` - срочно остановить все _worker_'ы (_immediate shutdown_)

Используя _self-pipe_ трюк, обработчики входящих сигналов добавляют идентификатор сигнала в Ruby массив и записывают в _Unix pipe_ сообщение '.' (в принципе можно слать любые данные), чтобы разбудить ожидающий основной поток _master_'а. _master_ все время блокирующие читает из этого _pipe_'а, периодически просыпаясь по _timeout_, чтобы проверить состояние _worker_'ов. Когда приходит сообщение в _pipe_, он проверяет массив накопленных сигналов (обычно только с одним элементом) и по очереди выполняет команды.

Далее проверяется есть ли завершенные дочерние процессы ("зомби"), зависшие процессы и было ли динамически изменено количество _worker_'ов.

При завершении работы веб-сервера все worker'ы "вежливо" завершаются и удаляется PID-файл.



#### Дочерние зомби-процессы

_master_ процесс контролирует количество _worker_'ов, поэтому должен определять когда _worker_ процесс завершается. Возможны разные подходы, но здесь используется механизм операционной системы. Когда дочерний процесс завершается его родителю шлется сигнал `CHLD`, а сам процесс переходит в состояние ["зомби"](https://en.wikipedia.org/wiki/Zombie_process). Все его ресурсы освобождаются (оперативная память, дескрипторы, объекты ядра), но метаинформация (например код завершения) может быть полезна и остается в системе. Unicorn использует системный вызов [`waitpid`](https://linux.die.net/man/2/waitpid) с флагом `WNOHANG`, чтобы без блокирования получить список PID завершенный дочерних процессов.

Если есть завершенный _worker_, то _master_ удаляет его из списка _worker_'ов, закрывает _pipe_'ы для него и вызывает `after_worker_exit` _hook_. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L398-L415))



#### Зависшие worker'ы

Unicorn отслеживает для каждого _worker_'а время начала последнего обработанного запроса. Если время обработки запроса превысила _timeout_, ему шлется системных сигнал `KILL` и этот процесс останавливается.

Интересен механизм передачи этих данных от _worker_'а _master_'у. _worker_ обновляет _timestamp_ при получении/завершении запроса, и эта информация становится доступной в процессе _master_'а. Для этого используется `gem` [raindrops](https://bogomips.org/raindrops/), который позволяет совместно использовать счетчики всеми дочерними процессами через разделяемую память. Эта статистика даже может быть доступна на `/_raindrops` странице, если добавить специальное [_middleware_](https://bogomips.org/raindrops/Raindrops/Middleware.html) ([пример страницы статистики](https://raindrops-demo.bogomips.org/_raindrops)).

Забавно, но согласно реализованной логике, если _worker_ обработал хотя бы один запрос и затем начал простаивать, то он будет завешен и поднимется новый _worker_ с чистым счетчиком, который уже будет игнорироваться этим механизмом ровно до первого входящего запроса. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L498-L517))



#### Обработка сигналов

Управляющие сигналы обрабатываются следующим образом:

`QUIT` - "вежливо" (_graceful_) остановить веб-сервер. _master_ рассылает всем _worker_'ам команды "вежливо" остановиться. Команда передается _worker_'у через заранее открытый _pipe_ - в него просто записывается числовой номер сигнала. Далее с интервалом в 0.1 секунды _master_ повторяет рассылку в течение сконфигурированного _timeout_'а или пока все _worker_'ы не остановятся и подчищает за процессами-зомби (делая системный вызов `waitpid2`). Если по завершению остались какие-то _worker_'ы, их останавливают принудительно посылкой системного сигнала `KILL`. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L340-L354))

Для `TERM` и `INT` процедура аналогичная, но в отличии от "вежливой" остановки, через _pipe_ _master_ отправляет _worker_'ам номер другого сигнала - `TERM` вместо `QUIT`.

`USR1` - переоткрыть файлы логов. Это распространенная практика периодически (например раз в день) архивировать логи приложения. Особенности организации файловых систем Unix’ов позволяют переместить открытый процессом файл в другую директорию не прерываю чтение/запись в него. Но чтобы процесс создал новый файл и начал писать в него, его надо переоткрыть. Чтобы это проходило незаметно для приложения как раз и нужен сигнал `USR1`.

Предполагается следующий сценарий. Файлы логов перемещаются в директорию с архивами, приложение продолжает писать в эти файлы. Далее шлется сигнал `USR1` и Unicorn принудительно переоткрывает все открытые файлы _master_'а и всем _worker_'ам рассылается команда аналогично переоткрыть лог-файлы (команда `USR1`).

Переоткрываются только файлы удовлетворяющие следующим условиям:
- файл открыт на чтение ('w') или дозапись ('a')
- или файл уже был перемещен и на его месте создан уже другой с таким же именем

В последнем случае проверяются _inode number_ открытого файла и файла находящемуся по тому же пути.  После этого приложение будет писать в новые файлы с теми же путями ничего не заметив. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/util.rb#L25-L89))

`USR2` - запустить новый _master_ процесс Unicorn'а.

`WINCH` - "вежливо" завершить все процессы _worker_'ы но оставить запущенным _master_. Если используется предзагрузка приложения (опция `preload_app`), то в случае необходимости _worker_'ы можно моментально запустить послав сигнал `TTIN`. Эта команда обрабатывается только если Unicorn запущен в фоне, иначе она игнорируется.

Временно блокируется автоматический запуск новых процессов _worker_'ов. Всем _worker_'ам шлется команда `QUIT`

`TTIN` - увеличиваем количество _worker_'ов на 1. Фактически новый процесс будет запущен на следующей итерации цикла после засыпания _master_'а в ожидании сигнала. Снимаем блокировку создания новых _worker_'ов если такова была после сигнала `WINCH`.

`TTOU` - уменьшить количество _worker_'ов на 1. Все аналогично `TTIN`.

`HUP` - перечитать Unicorn конфигурационный файл и "вежливо" пересоздать все _worker_'ы. Если конфигурационный файл не был указан вообще, то выполняется просто перезапуск Unicorn’а. В противном случае выполняются следующие действия:

```
load Unicorn config
run after_reload hook
shutdown workers gracefully
reopen log files

if not (configured to preload application)
    load application from config.ru file

reload all application-specific gems
```
[source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L766-L781)

Интересно как выполняется перезагрузка _gem_'ов - используется метод `Gem.refresh` из Rubygems. Если делается загрузка приложения, то будут подхватываться изменения в исходном коде приложения.

Если при переоткрытии лог-файлов произошла любая ошибка, то _master_ завершается с кодом 77 (`EX_NOPERM` - You did not have sufficient permission to perform the operation) следуя [конвенции кодов ошибок](https://man.openbsd.org/sysexits.3)

`CHLD` - это сигнал посылается операционной системой если завершился один из дочерних процессов. _master_ процесс получает этот сигнал если завершился  _worker_ процесс или новый _master_ при перезапуске. Обработчик просто будит _master_ и тот определяет PID'ы завершившихся процессов и удаляет ненужную больше информацию о _worker_'ах.


### Перезапуск master процесса

```
# master process:
if already in re-executing state
    if new master process exists
        return

rename pid file to "#{pid}.oldbin”
fork
set process name "master (old)"
```

```
# new master process:
pack socket descriptors into UNICORN_FD ENV variable
change directory to CWD from start context
avoid leaking file unknown socket descriptors
run before_exec hook
exec
```
[source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L417-L462)

Здесь используется стандартный подход `fork` + `exec`. _master_ создает дочерний процесс, который наследует все дескрипторы сокетов и затем загружает в память совершенно новую программу. Выполняется та же самая консольная команда, которой был запущен старый _master_ (эти данные были сохранены в начальный контекст), но окружение уже может измениться:
- текущая директория может быть изменена (если символическая ссылка и после деплоя указывает на директорию с новым релизом),
- Unicorn может быть уже другой версии,
- исходный код тоже может быть обновлен.

В `Kernel#exec` кроме консольной команды передается параметры в виде `Hash` с парами вида `{fd => socket}`. Это означает перенаправление файлового дескриптора в дочернем процессе на файловый дескриптор в родительском (_redirect to the file descriptor in parent process_). Краткое описание параметров и редиректа можно найти в документации по [`Process.spawn`](https://ruby-doc.org/core-2.6.1/Process.html#method-c-spawn).

Новый _master_, как было описано выше, возьмет из переменной окружения `UNICORN_FD` числовые дескрипторы унаследованных серверных сокетов и активирует их. Новые _worker_'ы могут сразу же начинать принимать входящие соединения параллельно с _worker_'ами старого _master_'а. Поэтому в `after_fork` _hook_'е, который будет запускаться в процессе _worker_'а при старте, обычно завершают старый _master_ посылая ему сигнал `QUIT`.

Если новый _master_ процесс по каким-то причинам завершается, старый master узнает об этом используя `waitpid2` системный вызов, точно так же как и для завершившихся _worker_ процессов, и откатывает сделанные изменения:
- переименовывает обратно pid-файл и
- переименовывает сам _master_ процесс.

Для проверки существует ли еще новый _master_ используется трюк с `kill 0` - посылается 0-й (несуществующий) сигнала процессу нового _master_'а. Из [`kill (2)`](http://man7.org/linux/man-pages/man2/kill.2.html):

> "If sig is 0, then no signal is sent, but existence and permission
> checks are still performed; this can be used to check for the
> existence of a process ID or process group ID that the caller is
> permitted to signal."

Чтобы избежать утечки дескрипторов всем дескрипторам из системного диапазона 3-1024 кроме серверных сокетов выставляется флаг _close-on-exec_ (`FD_CLOEXEC`), чтобы эти дескрипторы были закрыты в дочернем процессе ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L489-L496)).

Ссылки:
* [Fork–exec (Wikipedia)](https://en.wikipedia.org/wiki/Fork%E2%80%93exec)



#### Передача переменной окружения дочернему процессу

Давайте проиллюстрируем это примером на Ruby:

```ruby
# exec.rb

ENV['UNICORN_FD'] = '1'
exec 'ruby puts.rb'

# puts.rb

if ENV['UNICORN_FD']
  puts "UNICORN_FD = #{ENV['UNICORN_FD']}"
else
  puts "UNICORN_FD is nil"
end
```

```shell
> ruby exec.rb
#=> UNICORN_FD = 1
```
Как видим, переменная окружения будет доступна в дочернем процессе даже после системного вызова `exec`.

#### Активация унаследованного сокета

Давайте посмотрим на примере как работает трюк с передачей дескрипторов серверных сокетов в новый _master_ через переменную окружения и активация сокетов.

Здесь мы создадим серверный сокет, затем запустим дочерний процесс с совершенно другим скриптом `server_child.rb` и передадим в него файловый дескриптор серверного сокета. В дочернем процессе мы активируем сокет и начнем принимать соединение в обоих процессах на одном и том же сокете. Далее в скрипте `client.rb` мы будем соединяться с сервером попадая то на один сервер то на другой, читать сообщение от сервера и печатать его.

```ruby
# server.rb

require 'socket'

server = TCPServer.new 2000

fork do
  ENV['SOCKET_ID'] = server.fileno.to_s
  exec 'ruby server_child.rb', server.fileno => server
end

loop do
  client = server.accept
  client.puts "Hello from server #{$$}!"
  client.close
end
```

```ruby
# server_child.rb

require 'socket'

fileno = Integer(ENV['SOCKET_ID'])
server = TCPServer.for_fd(fileno)

loop do
  client = server.accept
  client.puts "Hello from server child #{$$}!"
  client.close
end
```

```ruby
# client.rb

require 'socket'

loop do
  s = TCPSocket.new 'localhost', 2000
  line = s.gets
  puts line
  s.close

  sleep 1
end
```

```shell
# shell

> ruby server.rb

# another shell
> ruby client.rb
Hello from server child 69055!
Hello from server 69042!
Hello from server child 69055!
Hello from server 69042!
Hello from server child 69055!
Hello from server 69042!
Hello from server 69042!
Hello from server 69042!
Hello from server child 69055!
Hello from server child 69055!
```

Интерес представляет строчка с `exec`:

```ruby
exec 'ruby server_child.rb', server.fileno => server
```

Здесь вторым аргументом передаются `Hash` с правилами редиректа между дескриптором дочернего процесса и родительского. Если его опустить, то активировать сокет в дочернем процессе не получится. Будет выдаваться ошибка "Bad file descriptor":

```
Traceback (most recent call last):
    1: from server_child.rb:7:in `<main>'
server_child.rb:7:in `for_fd': Bad file descriptor - fstat(2) (Errno::EBADF)
```

Это похоже на особенность реализации Ruby. После системного вызова `fork` активация работает, но после `exec` уже нет. В дочернем процессе можно задать произвольный файловый дескриптор и перенаправить его на заданный дескриптор родительского процесса. ([source](https://github.com/ruby/ruby/blob/v2_6_0/spec/ruby/core/process/exec_spec.rb#L200-L214))

Проиллюстрируем это на примере с наследованием и активацией файла:

```ruby
# file.rb

file = File.open('file.txt', 'w')
new_fileno = file.fileno + 100

fork do
  ENV['FILE_FD'] = new_fileno.to_s
  exec 'ruby file_child.rb', new_fileno => file
end

file.puts "Hello from file.rb"

Process.wait

puts "Bye from file.rb"
```

```ruby
# file_child.rb

raise if ENV['FILE_FD'].nil?

fileno = Integer(ENV['FILE_FD'])
file = File.for_fd(fileno)

file.puts "Hello from file_child.rb"
file.close

puts "Bye from file_child.rb"
```

```shell
# shell

> ruby file.rb
Bye from file_child.rb
Bye from file.rb

> cat file.txt
Hello from file_child.rb
Hello from file.rb
```

Обратите внимание на строчки

```ruby
new_fileno = file.fileno + 100
```
и
```ruby
exec 'ruby file_child.rb', new_fileno => file
```

Мы берем произвольное незанятой число `new_fileno` и указываем, что в дочернем процессе по этому дескриптору будет доступен унаследованный файл. Без такого явного редиректа дескриптор не будет доступен и активация будет приводить к такому же исключению "Bad file descriptor (Errno::EBADF)".



### Что происходит в worker'е

```
wait for incoming connection or message from master in pipe
    if received message from master
        for each received message in pipe
            if received EOF
                handle it like QUIT signal

                set new handler for this signal - IGNORE
                call previous handler
                set previous handler again

            if received USR1
                reopen log files
    else
        for each incoming connection
            save timestamp of starting
            accept new connection
            process request

        until no incomming connections
            try to accept and process connections from these sockets

        save timestamp

        if master process dead
            return
```
[source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L676-L725)

Процесс _worker_'а обрабатывает все входящие запросы, а также команды от _master_, переданные через _pipe_.

Процесс завершается если:
- завершился сам _master_,
- _master_ прислал команду завершения или
- получен системный сигнал завершиться (`QUIT`, `TERM`, `INT`).

Команда передается в виде номера системного сигнала, который распаковывается и вызывается установленный ранее обработчик для этого сигнала. Чтобы этот обработчик не был прерван этим же сигналом, но уже настоящим, обработка этого сигнала блокируется.

Одновременно может прийти несколько входящих соединений. _worker_ обрабатывает их по очереди и запоминает _timestamp_ начала обработки текущего запроса. Этот _timestemp_ _master_ использует, чтобы определить зависший _worker_, который превысил _timeout_ обработки запроса и завершить его.

Далее _worker_ не спешит снова вызывать `IO.select` и ждать входящих соединений. Он думает: - "Раз по текущим сокетам пришли запросы, которые мы уже обработали, наверное за это время могли прийти и другие запросы на эти сокеты. Надо это проверить." И _worker_ начинает принимать соединения на сокетах, которые были получены в последнем вызове `select`, до тех пор пока соединения не перестанут поступать. Только тогда _worker_ закончит эту итерацию и сделает новый вызов `select`, проверяя соединения на всех серверных сокетов. Из этого следует любопытный вывод. Если сервер слушает несколько сокетов, то возможна ситуация, когда некоторые из них будут игнорироваться и ждать пока по другим не перестанут приходить соединения.

Далее _worker_ проверяет не умер ли _master_. Непонятно зачем эта дополнительная проверка нужна ведь _worker_ и так узнает это по закрытию _pipe_’а. Но интересен сам трюк:

```ruby
ppid == Process.ppid or return
```

Здесь сравниваются PPID (_parent process id_) на момент запуска _worker_'a с PPID на текущий момент. На первый взгляд это не имеет смысла, но оказывается, что когда родительский процесс умирает, операционная система изменяет PPID осиротевшего дочернего процесса на PID процесса init (PID 1). На самом деле все намного сложнее и полагаться на магическое число не стоит, как развернуто [объяснили](https://unix.stackexchange.com/a/177361/16396) на stackexchange это _"implementation-defined process"_. Есть возможность задавать процесс, который "унаследует" осиротевший процесс, так называемый _subreaper_. Если _subreaper_ не задан, то только тогда родителем становится процесс init. Это используют супервизоры, такие как systemd и upstart.

Для _pipe_'ов используется обертка `Kgio::Pipe` из _gem_'а [kgio](https://bogomips.org/kgio/). Этот `gem` разработанный специально для проекта Unicorn:

> “This is a legacy project, do not use it for new projects. Ruby 2.3 and later should make this obsolete. kgio provides non-blocking I/O methods for Ruby without raising exceptions on EAGAIN and EINPROGRESS."

В Ruby 2.3 действительно появились нативные не блокирующие операции над сокетами "_nonblock":
`Socket#connect_nonblock`, `Socket#accept_nonblock`, `TCPServer#accept_nonblock`, `UNIXServer#accept_nonblock`, `BasicSocket#recv_nonblock`, `BasicSocket#recvmsg_nonblock`, `BasicSocket#sendmsg_nonblock`.

Поэтому этот `gem` уже потерял свою актуальность и вероятно в будущих релизах будет убран из Unicorn'а вместе с поддержкой Ruby 2.3.



#### Обработка HTTP запроса

```
read partially request from socket

if check_client_connection option
    check if socket isn't closed by client

call application

if full socket hijacking
    return

if response status == 100
    send 100 in response
    call application

write a response to a socket

if response body is a file
    close it

shutdown socket
close socket
```
[source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L602-L627)

Unicorn читает начало HTTP запроса, парсит заголовки и подготавливает объект с информацией о запросе, чтобы передать его потом приложению. Согласно спецификации Rack этот объект называется `environment` и должен быть `Hash` объектом, в котором будут переданы HTTP заголовки, _body_ POST запроса и метаинформация.

Unicorn читает только доступные прямо сейчас в сетевом буфере данные (ведь запрос может быть большим и пришла только часть данных) блоками по 16kb ([source](https://github.com/defunkt/unicorn/blob/master/lib/unicorn/http_request.rb#L77-L83)) не дожидаясь пока прийдет весь запрос до конца. На данном этапе главное это распарсить заголовки. Согласно спецификации сокет передается приложению в виде `env[‘rack.input’]` и оно должно дочитать запрос до конца. Парсинг _multipart_ запроса также ложиться на плечи приложения. По спецификации Rack `env['rack.input']` должен поддерживать метод `rewind`, и после его вызова чтение запроса продолжиться сначала. В Unicorn это работает по умолчанию, хотя и может отключаться ради ускорения обработки запросов. Чтобы сделать `rack.input` не- _rewindable_ нужно указать конфигурационную опцию `rewindable_input=false`. По умолчанию при чтении запроса все данные будут сохраняться во временный файл, а когда запрос будет прочитан до конца, все последующие операции чтения будут делаться уже из него. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/tee_input.rb))

Если выставлена конфигурационная опция `check_client_connection`, то перед передачей запроса приложению Unicorn попытается проверить не отвалился ли клиент и не закрыл ли сокет пока его запрос ждал обработки. Согласно документации это сработает только для локального клиента, который запущен на том же компьютере. Статус сокета пытаются определись из его системных опций (делая системный вызов [`getsockopt`](http://man7.org/linux/man-pages/man2/getsockopt.2.html)). Формат опций специфичен для операционной системы и если не получилось с ними то Unicorn просто пишет начало ответа ("HTTP'.freeze, '/1.1 ") ожидая получить ошибку `EPIPE`. Эта означает "The local end has been shut down" - т.е. сокет или _pipe_ закрыт на чтение и никто из него уже не прочитает данные.

Unicorn поддерживает [_full socket hijacking_](https://old.blog.phusion.nl/2013/01/23/the-new-rack-socket-hijacking-api/). Это означает, что после того как веб-сервер прочитал и распарсил HTTP запрос и передал его приложению, оно получает доступ к сокету напрямую и может реализовать произвольный протокол передачи данных свободно читая и записывая в сокет. Когда приложение обработало запрос веб-сервер определяет произошел ли _hijacking_ и в этом случае просто закрывает соединение игнорируя заголовки и _body_, которые вернуло приложение. _Socket hijacking_ это часть спецификации Rack и поддерживается всем Rack совместимыми веб-серверами кроме WEBrick. Это нашло применение, к примеру, в реализации _websocket_'ов в Rails.

Unicorn обрабатывает код возврата 100 (Continue) особым образом. HTTP протокол по дизайну statelessness, т.е. веб-сервер не имеет собственного состояния. Протокол перестает следовать этому принципе в случае с кодом 100. Клиент, предполагая, что сервер может отказаться обрабатывать запрос, может отправить только HTTP заголовки и спросить сервер, будет ли он вообще обрабатывать такой запрос. Если сервер подтверждает, то клиент шлет body запроса. Это нужно, например, если запрос очень большой. Нет смысла слать весь запрос если сервер по заголовкам может понять, что не будет его обрабатывать. Это работает следующим образом: клиент шлет только заголовки, включая заголовок "Expect: 100-continue”, и ждет ответа от сервера. Сервер должен ответить 417 (Expectation Failed) если не принимает такой запрос и 100 (Continue) если разрешает продолжить. Далее клиент шлет body запроса и сервер возвращает обычный ответ, второй раз.

Именно поэтому если приложение отвечает 100 код, то Unicorn игнорирует заголовки и _body_ и записывает промежуточный ответ 100 (Continue). Далее он удаляет Expect заголовок из запроса и еще раз вызывает приложение. Затем он проверяет был ли _socket hijacking_ и если нет, то отсылает ответ приложения.

Unicorn также поддерживает _partial socket hijacking_. Это означает, что веб-сервер отправляет заголовки, которые вернуло приложение, но игнорирует _body_. Вместо этого Unicorn предоставляет приложению сокет и приложение шлет данные самостоятельно. Предполагается, что это поможет реализовать стриминг приложением. Это реализовано следующим образом: приложение в ответе возвращает заголовок `rack.hijack`, значение которого это _callable_ объект, который Unicorn вызывает и передает аргументом сокет ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_response.rb#L56)).

В конце кроме закрытия сокета (`close (2)`) также делается системный вызов [`shutdown (2)`](https://linux.die.net/man/2/shutdown). Согласно комментариям это нужно если само приложение сделало `fork`. И правда, системный вызов `close` закрывает сокет только в текущем процессе, в то время как `shutdown` говорит операционной системе закрыть все копии этого сокета во всех родительских и дочерних процессах.

Ссылки:
* [The new Rack socket hijacking API](https://old.blog.phusion.nl/2013/01/23/the-new-rack-socket-hijacking-api/)
* [Спецификация Rack](https://www.rubydoc.info/github/rack/rack/master/file/SPEC)
* [ Hypertext Transfer Protocol -- HTTP/1.1. Use of the 100 (Continue) Status](https://www.w3.org/Protocols/rfc2616/rfc2616-sec8.html#sec8.2.3)
* [Closing a Socket After Forking](https://www.cs.ait.ac.th/~on/O/oreilly/perl/cookbook/ch17_10.htm)



#### Обработка ошибок

При обработке запроса могут возникать ошибки. Если клиент, например, отвалился, веб-сервер ничего не может сделать и просто прекращает обработку этого запроса. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L566-L589))

Если превышена длина URI, то возвращается 414 код ошибки. Есть и другие ограничения:
* имя заголовка - 256b
* значение заголовка - 80kb
* _URI_ - 15kb
* _path_ - 4kb
* _query string_ - 10kb

Если произошла любая ошибка парсинга запроса, то возвращается 400 код.
Если приложением бросается любое исключение, то веб-сервер отдает 500 код.

Ссылки:
* [Спецификация Rack](https://www.rubydoc.info/github/rack/rack/master/file/SPEC)
* [Building a Rack Web Server in Ruby](https://ksylvest.com/posts/2016-10-04/building-a-rack-web-server-in-ruby)
* [Rhino, simple Ruby server that can run rack apps](https://github.com/ksylvest/rhino)
* [Ragel State Charts](https://zedshaw.com/archive/ragel-state-charts/)
* [The new Rack socket hijacking API](https://old.blog.phusion.nl/2013/01/23/the-new-rack-socket-hijacking-api/)



### Timeout и время

При определением зависшего _worker_'а для получения текущего времени используется не обычный `Time.now`, а делается специальный системный вызов [`clock_gettime`](https://linux.die.net/man/2/clock_gettime) используя Ruby обертку [`Process.clock_gettime(Process::CLOCK_MONOTONIC)`](https://ruby-doc.org/core-2.6.1/Process.html#method-c-clock_gettime). Как видно из имени константы `CLOCK_MONOTONIC` будет возвращено монотонное время. Здесь очень важно использовать именно монотонное (т.е. не убывающее) время так как мы сравниваем два `timestamp`'а и определяем разницу между ними. Что будет, если системные часы были переведены назад на 1 минуту вручную или NTP сервисом? Мы получим совершенно некорректную отрицательную разницу там где ожидалась положительная. Это источник очень неприятных багов. Кстати, монотонное время может даже не быть временем совсем - это может быть, например, количество секунд с момента включения компьютера.

Ссылки:
* [Реализация Process.clock_gettime в Ruby](https://github.com/ruby/ruby/blob/v2_6_0/process.c#L7597-L7880)
* [Monotonic Clocks – the Right Way to Determine Elapsed Time](https://www.softwariness.com/articles/monotonic-clocks-windows-and-posix)


### Послесловие

Unicorn это во всех смыслах традиционное Unix приложение. Он интенсивно использует системные вызовы и просто напичкан разными трюками, например:
* демонизация,
* _self-pipe_ трюк,
* определение завершившихся дочерних процессов,
* определение завершения родительского процесса по изменившемуся PPID,
* активация сокетов
* поддержка systemd.

Это хороший и компактный пример для знакомства как с системными вызовами Unix в общем так и с процессами и синхронизацией между ними в частности.

Давайте перечислим системные вызовы, которые здесь используются:

* `kill` - для отправки _master_'ом сигналов _worker_'у
* `signal`/`sigaction` -  задать обработчик сигнала
* `fork` - для создания нового процесса - нового _worker_'а или нового _master_'а
* `exec` - запустить новую программу в текущем процессе
* `setsid` - создать сессию и группу процессов
* `waitpid2` - для получения PID завершившийся дочерних процессов (_worker_'ов)
* `getppid` - получить PID родительского процесса
* `clock_gettime` - получить монотонное время
* `select` - для ожидания входящих соединений по сокетам или данных в _pipe_
* `accept` - для приема нового соединения и создания клиентского сокета
* `getsockopt` - для проверки опций сокета и его статуса - не закрыт ли он уже
* а также работы с сокетами и _pipe_'ами - создание/закрытие/чтение/запись.

Читая исходный код возникло сильное впечатление чужеродности. Разработчики практически не использовали богатые возможности Ruby как языка, его коллекции, замыкания, а если использовали, то это скорее запутывало чем делало код чище и яснее. Думаю, если переписать весь код на Си, то в нем мало что изменится. Он останется таким же запутанным, переусложненным и с непродуманными именами переменных и методов.

#### Ссылки

* [Unicorn homepage](https://bogomips.org/unicorn)
* [Official Git repository](https://bogomips.org/unicorn.git/tree)
* [Unofficial Unicorn Mirror on GitHub](https://github.com/defunkt/unicorn)
* [Unicorn Unix Magic Tricks](https://thorstenball.com/blog/2014/11/20/unicorn-unix-magic-tricks)
* [Unicorn! (GitHub blog)](https://github.blog/2009-10-09-unicorn)
* [Бах. Архитектура операционной системы Unix](https://blog.heroku.com/unicorn_rails)

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
