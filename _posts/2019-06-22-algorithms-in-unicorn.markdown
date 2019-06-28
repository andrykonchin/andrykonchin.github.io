---
layout: post
title:  "Алгоритмы в Unicorn"
date:   2019-06-22 00:37
categories: Ruby
---

Unicorn это один из самых популярных веб-серверов для Ruby. Если кратко, то это Rack-совместимый классический _fre-fork_ веб-сервер. Он следует принципу "Do one thing, do it well” и поэтому не умеет HTTPS, _keep-alive_, HTTP _pipelining_ и не предназначен для обработки медленных клиентов. Кроме того, он поддерживает только Unix системы.

<img src="/assets/images/2019-06-22-algorithms-in-unicorn/unicorn.jpg" style="width: 20em; margin-left: auto; margin-right: auto;" />


Я начинал разбиратсья с Unicorn просто из любопытства и неожиданно для себя начал погружаться в тонкости программирования под Unix. Оказалось, что Unicorn интенсивно использует системные вызовы для работы с процессами и коммуникации между ними. Также мне было интересно разбираться каким образом эти системные вызовы доступны в стандартных библиотеках Ruby.

В этом посте мы разберем по шагам как Unicorn работает изнутри, как организовано управление процессами, как обрабатываются входящие HTTP запросы и все то, что не описано в документации.



### Содержание
{:.no_toc}

* A markdown unordered list which will be replaced with the ToC, excluding the "Contents header" from above
{:toc}



### Кратко об архитектуре

Unicorn использует традиционную для Unix многопроцессную модель конкурентности. Среди альтернативных вариантом можно упомянуть многопоточность, _event loop_, _user-space threads (aka coroutines/goroutines)_ и, наконец, акторы.

В подходе с множеством процессов каждый входящий HTTP запрос обрабатывается в своем системном процессе операционной системы. Соответственно, количество одновременно обрабатываемых запросов ограничивается количеством запущенных процессов. В Unicorn запускается сконфигурированное количество процессов, которое подбирается экспериментально обычно исходя из количества ядер процессора и характера ожидаемой нагрузки (пропорции _CPU-bounded_ и _IO-bounded_ операций в обработке запросов).

Unicorn запускает один главный _master_ процесс и процессы для обработки HTTP запросов, _worker_'ы. Основная задача _master_ процесса - управлять _worker_'ами. В свою очередь _master_'ом можно управлять системными сигналами, которые посылаются из консоли вручную или из _shell_-скрипта используя команду `kill <сигнал> <PID>` (например `kill -s QUIT 2378`). После запуске веб-сервера _worker_'ы ожидают входящие сетевые соединения на сконфигурированных портах. Если говорить точнее, то можно задать не только локальный порт но и IP-адрес, если сервер имеет несколько сетевых интерфейсов. Поддерживаются как TCP так и UNIX сокеты.

<img src="/assets/images/2019-06-22-algorithms-in-unicorn/architecture.svg"/>

Если посмотреть на вывод команды `ps`, можно легко различить _master_ процесс и _worker_'ы:

<pre>
$ ps -f --forest -C ruby
UID        PID  PPID  C STIME TTY          TIME CMD
deployer 20398     1  0 13:02 ?        00:00:20 unicorn_rails master -c /var/www/sites/my-blog/current/config/unicorn.rb -D
deployer 21066 20398  0 13:03 ?        00:00:09  \_ unicorn_rails worker[0] -c /var/www/sites/my-blog/current/config/unicorn.rb -D
deployer 21068 20398  0 13:03 ?        00:00:10  \_ unicorn_rails worker[1] -c /var/www/sites/my-blog/current/config/unicorn.rb -D
</pre>

В данной конфигурации поднято всего два дочерних _worker_ процесса. Обратите внимание, что _PPID_ _worker_'ов совпадает с _PID_ _master_ процесса.

Может показаться странным, как несколько процессов могут совместно обрабатывать входящие соединения на одном и том же порту. Ведь обычно если один процесс слушает какой-то порт, он (этот порт) становится занятым и другой процесс уже не может открыть новый серверный сокет на этом порту. Совместное использование порта становится возможно из-за особенности архитектуры Unix и механизма создания дочерних процессов. _master_ процесс при запуске читает конфигурацию и открывает серверные сокеты. Затем он порождает дочерние процессы _worker_'ы, которые наследуют все его системные ресурсы. В том числе и файловые дескрипторы - открытые файлы, сокеты и _Unix-pipe_'ы. Поэтому, фактически, в операционной системе создается только один серверный сокет с одной _backlog_-очередью входящих соединений, который доступен во всех _worker_'ах. В этом случае операционная система сама распределяет входящие соединения из _backlog_-очереди среди всех свободных _worker_'ов.

На самом деле есть и другой более универсальных механизм совместного использования порта произвольными не родственными процессами и Unicorn его даже поддерживает (`reuseport` опция команды `listen` в конфигурационном файле). Это так называемая опция отктырия сокета `SO_REUSEPORT`. Если указать ее при первом открытии сокета на порту в одном процессе, то любой другой процесс сможет тоже совместно использовать этот порт и открывать свой собственный серверный сокет на нем. В этом случае эти серверные сокеты будут независимыми и будут иметь свои собственные _backlog_-очереди входящих соединений.

Ссылки:
* [Concurrency Deep Dive: Multi-process](https://blog.appsignal.com/2017/03/07/ruby-magic-concurrency-processes.html)
* [Mastering Concurrency](https://blog.appsignal.com/2016/03/17/ruby-magic-mastering-concurrency.html)
* [Guide to Multi-processing Network Server Models](https://www.toptal.com/software/guide-to-multi-processing-network-server-models)
* [The SO_REUSEPORT socket option](https://lwn.net/Articles/542629/)



### Запуск Unicorn

```
parse command line options
if passed "-D" or "—daemonize" command line option
    daemonize
start HTTP server
```
[source](https://github.com/defunkt/unicorn/blob/v5.5.1/bin/unicorn)

Unicorn запускается консольной командой `unicorn` из директории приложения. Поддерживается совместимость с опциями таких команд как `ruby` и `rackup` (из _gem_’а Rack).

В Unicorn намеренно избегают конфигурацию через опции командной строки в пользу конфигурационного файла, который обычно кладут в `config/unicorn.rb`. Это упрощает код так как в этом случае есть только один источник конфигурации вместо двух.



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

Здесь происходит следующее. Процесс, запущенный в консоле (_grandparent_), открывает _Unix pipe_ для общения с дочерними процессами. Далее он создает дочерний процесс делая системный вызов `fork` ([`fork(2)`](http://man7.org/linux/man-pages/man2/fork.2.html)) и засыпает ожидая входящие данные в _pipe_'е. Любое сообщение в нем будет означать, что веб-сервер в дочернем процессе успешно запустился. Получив это уведомление _grandparent_ процесс успешно завершается.

<img src="/assets/images/2019-06-22-algorithms-in-unicorn/daemonizing.svg"/>

Если _master_ процесс (внук) не смог стартовать веб-сервер и неуспешно завершился, то _pipe_ закрывается операционной системой и в него шлется признак _EOF_ (_End Of File_). _Grandparent_ понимает, что _master_ процесс завершился с ошибкой, выводит об этом сообщение в _STDOUT_ и сам завершается.

Дочерний (_parent_) процесс выполняет только одно действие - делает системный вызов `setsid` ([`setsid(2)`](http://man7.org/linux/man-pages/man2/setsid.2.html)). Как следствие создается новая сессия процессов, в ней создается новая группа процессов и _parent_ процесс становится лидером как сессии так и группы. Все дочерние процессы (как _master_ так и _worker_'ы) будут входить в эту группу и сессию.

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

Затем создается еще один _Unix-pipe_ (назовем его _self-pipe_). О нем будет подробнее чуть позже.

После этого регистрируются обработчики системных сигналов. Unicorn обрабатывает следующие сигналы: `WINCH`, `QUIT`, `INT`, `TERM`, `USR1`, `USR2`, `HUP`, `TTIN`, `TTOU` и `CHLD`.

В конфигурационном файле можно задать опцию `preload_app`. Это означает, что приложение будет загружено и инициализировано заранее в _master_ процессе, а _worker_'ы получат уже загруженное приложение, готовое к обработке входящих запросов. Это делает запуск нового _worker_'а практически мгновенным. Если эта опция не выставлена, то каждый _worker_ будет загружать и инициализировать приложение независимо. Это никак не влияет на время запуска самого Unicorn'а, но будет вызывать дополнительную задержку при запуске нового _worker_'а на лету (если послать сигнал `TTIN`) или при автоматичеком запуске _worker_'а взамен внезапно завершенному. В большом Rails приложении старт окружения может занимать 30-50 секунд, поэтому `preload_app` это _must have_ опция.

Еще одно преимущество предварительной загрузки приложения это экономия оперативной памяти в процессах _worker_'ах. Из-за механизма операционных систем _Copy-On-Write_ память занимаемая Ruby-приложением может разделяться между _worker_'ами и _master_'ом. В большом Rails приложении процесс _worker_'а может занимать до 1-1.5 Gb, поэтому экономия памяти будет очень заметной.

Загрузка самого приложение оборачивается в анонимную функцию и выполняется либо в _master_ процессе либо в _worker_'ах. Для поддержки Rack DSL используется [`Rack::Builder`](https://github.com/rack/rack/blob/master/lib/rack/builder.rb) класс из Rack. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn.rb#L49-L94))

Для всех сконфигурированных адресов (кроме унаследованных от предыдущего _master_'а) открываются новые серверные сокеты. Задавая параметры `tries` и `delay` для каждого адреса независимо можно настроить повторные попытки открытия сокета, если адрес еще занят. По умолчанию будет 5 попыток с задержкой в 0.5 секунд. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L236-L263))

Далее _master_ создает процессы _worker_'ы, шлет сообщение в унаследованный от _grandparent_'а _pipe_, после чего тот завершается, и переходит в режим ожидания. В этом режиме _master_ обрабатывает входящие управляющие системные сигналы и мониторит состояние _worker_'ов.



#### Активация унаследованных сокетов

При перезапуске Unicorn используя связку системных вызовов `fork`+`exec` создает новый _master_ процесс, который наследует все файловые дескрипторы родительского процесса. Наследуются в том числе и открытые серверные сокеты. Хотя сами Ruby объекты сокетов при перезапуске в новом _master_'е конечно становятся недоступными (после системного вызова exec запускается новая Ruby VM), но файловые дескрипторы все еще можно использовать. Файловые дескрипторы это просто числа - номера из таблицы дескрипторов процесса, а после системного вызова `fork` дочерний процесс получает копию родительской таблицы файловых дескрипторов. Не смотря на то, что они называются файловыми, дескрипторы могут указывать и на другие системные объекты - сокеты и _pipe_'ы.

Учитывая это, чтобы избежать _downtime_'а, старый _master_ при перезапуске сохраняет дескрипторы открытых серверных сокетов (_aka_ слушающие сокеты) в переменную окружения `UNICORN_FD`. Новый _master_ их активирует и создает новые Ruby объекты сокетов продолжая принимать входящие соединения по ним и обрабатывать новые запросы. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L808-L845))

Также Unicorn поддерживает интеграцию с [systemd](https://en.wikipedia.org/wiki/Systemd) и активацию сокетов открытых внешним супервизором. Если настроить Unicorn как сервис в systemd и сконфигурировать активацию сокетов, то systemd будет открывать серверные сокеты заранее и при запуске Unicorn'а выставлять переменные окружения `LISTEN_PID` и `LISTEN_FDS`. Сконфигурированные серверные сокеты будут доступны в процессе Unicorn'а по дескрипторам начиная с 3 (0-2 уже заняты - `stdin`, `stdout` и `stderr`). В `LISTEN_FDS` передается число активированных сокетов, а в `LISTEN_PID` - _PID_ процесса, которому предназначены эти дескрипторы. Так как переменная окружения может быть доступна в других дочерних процессах, то важно активировать сокеты только в указанном процессе. Unicorn добавляет эти сокеты к другим, унаследованным при перезапуске сокетам от старого _master_'а (в случае если происходит перезапуск). Фактически Unicorn реализует функцию `sd_listen_fds` ([`sd_listen_fds(3)`](http://man7.org/linux/man-pages/man3/sd_listen_fds.3.html)). ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L813-L818))

Ссылки:
* [systemd for Developers I](http://0pointer.de/blog/projects/socket-activation.html)
* [Rethinking PID 1](http://0pointer.de/blog/projects/systemd.html)



#### Self-pipe трюк

_Self-pipe_ трюк это стандартный способ в Unix обрабатывать входящие сигналы процессов. [Сигналы](https://en.wikipedia.org/wiki/Signal_(IPC)) - это один из механизмов [IPC](https://en.wikipedia.org/wiki/Inter-process_communication) (Inter-process communication). Процесс может зарегистрировать свой обработчик конкретного сигнала и он будет вызываться операционной системой каждый раз, когда этому процессу отправят такой сигнал.

Трюк заключается в следующем. Процесс открывает _Unix pipe_ (_self-pipe_), регистрирует обработчики сигналов и блокирующе ждет данные в этом _pipe_. Обработчики сигналов не содержат никакой логики и просто пишут в этот _pipe_ сообщение о пришедшем сигнале, чтобы разбудить ждущий основной поток выполнения процесса ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L393-L396), [source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L132-L133))). Прочитав событие из _pipe_'а процесс синхронно обрабатывает его и снова ждет новых событий.

Такой подход должен решить проблему связанную с обработкой сигналов - проблему _re-entrancy_. Когда процессу приходит сигнал операционная система прерывает выполнение процесса и в одноим из его потоков (в любом произвольном на самом деле) выполняет обработчик этого сигнала (стандартный или переопределенный). Код приложение может быть прерван в любом месте - может быть прерван системный вызов (и это может привести к его завершению с ошибкой `EINT`), может быть прерван другой обработчик сигнала и даже этот же самый обработчик, если сигнал был послан несколько раз подряд и предыдущих обработчик еще не успел завершиться. Поэтому код обработчика должен обладать свойством _reentrancy_, т.е. может быть безопасно прерван самим собой.

Именно поэтому обработчики сигналов здесь не содержат системных вызовов и выполняются максимально быстро - идентификатор сигнала просто дописывается в Ruby-массив для отложенной обработки. Операция добавления элемента в массив в Ruby не атомарная, но здесь, видимо, этим пренебрегают. Теоретически элемент массива может быть перезаписан параллельной операцией и потеряться.

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

if master received signal to exit but didn't process it yet
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

Unicorn запускает указанное в конфиге количество _worker_'ов (по умолчанию только 1). Более того, можно изменять количество _worker_'ов динамически без перезапуска веб-сервера используя сигналы `TTIN` (увеличить на 1) и `TTOU` (уменьшить на 1). Процесс _worker_'а может завершиться сам или быть убитым _master_'ом если время обработки HTTP запроса превысило заданный _timeout_. В этом случае будет поднят новый процесс, чтобы сохранить заданное количество запущенных _worker_'ов.

Каждый _worker_ имеет свой уникальный номер. Он может быть повторно использован если процесс был завершен и новому процессу присвоят наименьший свободный номер.

Далее создается пара _Unix-pipe_'ов. _master_ процесс и _worker_'ы могут общаться через них, ведь _worker_'ы наследуют все открытые дескрипторы. _master_ может управлять _worker_'ом через один из _pipe_'ов, а _worker_ в свою очередь может определить неожиданное завершение _master_ процесса по закрытию второго _pipe_'а.

Затем запускается `before_fork` _hook_ и _master_ создает дочерний процесс делая системный вызов `fork`. Это обычная схема, которая работает с `preload_app` режимом.

Не так давно был добавлен ([вот в этом коммите](https://github.com/defunkt/unicorn/commit/ea1a4360d66a833d75fbd887388d8cd4fe4ae299)) другой механизм для запуска _worker_'ов - `fork` + `exec`. Очевидно, что при этом появляются накладные расходы на загрузку приложения. Но таким образом усиливается безопасность. Новый процесс запускает независимую Ruby VM и не разделяет память с родительским процессов. Это мера направлена на борьбу с [_address space discovery attacks_](https://en.wikipedia.org/wiki/Address_space_layout_randomization).

Этот механизм включается опцией `worker_exec`. Новый процесс _worker_'а должен выполнить те же шаги, что и _master_ процесс при перезапуске: проанализировать конфигурацию, активировать унаследованные файловые дескрипторы и загрузить приложение. Так как _master_ процесс в этом случае не разделяет с _worker_'ом ни память ни таблицу файловых дескрипторов, то для передачи _worker_'у выбранного порядкового номера и двух _Unix pipe_'ов для двунаправленного общения используется переменная окружения `UNICORN_WORKER`, в которую через запятую сохраняются эти три числа. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L464-L478))

Далее запускается `after_hook`. В него передаются два объекта (_server_ и  _worker_), интерфейс которых стабилен и открыт. Это, например, позволяет для отладки добавить еще один серверный сокет, специфичный для конкретного _worker_'а, или запустить процесс под другим пользователем.

```ruby
# config/unicorn.rb
after_fork do |server, worker|
  # per-process listener ports for debugging/admin:
  server.listen "127.0.0.1:#{9293 + worker.nr}"
  worker.user 'andrew'
end
```

Если приложение сконфигурировано с `preload_app=true`, то в `after_fork` обычно переоткрывают сетевые соединения, которые были созданы при загрузке приложения (например, к базе данных, Redis, RabbitMQ итд), иначе они будут одновременно использоваться всеми _worker_'ами. К примеру, до Rails 5 нужно было это явно делать для _pool_'а соединений к базе данных:

```ruby
before_fork do |server, worker|
  ActiveRecord::Base.connection.disconnect!
end

after_fork do |server, worker|
  ActiveRecord::Base.establish_connection
end
```

Unicorn, в свою очередь, пытается бороться с утечкой файловых дескрипторов при перезапуске _master_'а. Он закрывает все файловые дескрипторы (кроме серверных сокетов) в диапазоне 3...1024. Но при запуске _worker_'а это не делается.

Если задана конфигурационная опция `user`, то _worker_'ы будут запущены из под указанного пользователя (_master_ останется неизменным). Меняется _real_ и _effective_ _group ID_ и _real_ и _effective_ _user ID_ процессов. Также меняется _owner_ и _group_ лог-файлов. Фактически работает та же логика определения файлов, что и при перечитывании конфиг-файлов (при обработке `USR1` сигнала) - изменяются владелец и группа для всех открытых на запись/дозапись файлов в приложении. Любопытно, что для получения _user id_ по _username_ используется `Etc.getgrnam` ([Std-lib](https://ruby-doc.org/stdlib-2.6/libdoc/etc/rdoc/Etc.html#method-c-getpwnam)) из Ruby Std-lib - это интерфейс к конфигурационным файлам из `/etc` в Unix'ах.
([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/worker.rb#L112-L164))

Обратите внимание, что обработчик сигнала `QUIT` устанавливается два раза. В первый раз при старте процесса обработчик просто завершит процесс. Но после загрузки приложения и вызова всех _hook_'ов и перед началом обработки входящих запросов обработчик уже выполнит "вежливую" остановку - закроет сокеты и дождется завершения текущих запросов и только затем процесс завершится.



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

Согласно [документации](https://bogomips.org/unicorn/SIGNALS.html) к завершению работы Unicorn'а  приведут следующие сигналы:
* `QUIT` - дождаться завершения обработки всех текущих HTTP запросов (_graceful shutdown_),
* а `TERM` и `INT` - срочно остановить все _worker_'ы (_immediate shutdown_)

Используя _self-pipe_ трюк, обработчики входящих сигналов добавляют номер сигнала в Ruby-массив и записывают в _Unix pipe_ сообщение '.' (в принципе можно слать любые данные), чтобы разбудить ожидающий основной поток _master_'а. _master_ все время блокирующие читает из этого _pipe_'а периодически просыпаясь по _timeout_'у, чтобы проверить состояние _worker_'ов. Когда приходит сообщение в _pipe_, он проверяет массив накопленных сигналов (обычно в нем только один элемент) и по очереди выполняет команды.

Далее проверяется есть ли завершенные дочерние процессы ("зомби"), зависшие процессы и было ли динамически изменено количество _worker_'ов.

При завершении работы веб-сервера все _worker_'ы "вежливо" завершаются и удаляется _PID_-файл.



#### Дочерние зомби-процессы

_master_ процесс контролирует количество _worker_'ов и поэтому должен определять когда _worker_ процесс завершается. Возможны разные подходы, но здесь используется механизм операционной системы. Когда дочерний процесс завершается его родителю шлется системный сигнал `CHLD`, а сам процесс переходит в состояние ["зомби"](https://en.wikipedia.org/wiki/Zombie_process). Все его ресурсы освобождаются (оперативная память, дескрипторы, объекты ядра), но метаинформация (например код завершения) может быть полезна и остается в системе. Unicorn использует системный вызов `waitpid` ([`wait(2)`](http://man7.org/linux/man-pages/man2/waitpid.2.html)) с флагом `WNOHANG`, чтобы без блокирования получить список _PID_ очередных завершенный дочерних процессов.

Если есть завершенный процесс (_worker_), то _master_ удаляет его из списка _worker_'ов, закрывает _pipe_'ы для него и вызывает `after_worker_exit` _hook_. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L398-L415))



#### Зависшие worker'ы

Unicorn отслеживает для каждого _worker_'а время начала обработки последнего запроса. Если с этого момента прошло больше времени чем _timeout_, _worker_'у шлется системных сигнал `KILL` и процесс останавливается.

Интересен механизм передачи этих данных от _worker_'а _master_'у. _worker_ обновляет _timestamp_ при получении/завершении запроса и эта информация становится доступной в процессе _master_'а. Для этого используется `gem` [raindrops](https://bogomips.org/raindrops/), который позволяет совместно использовать счетчики всеми дочерними процессами через разделяемую память. Эта статистика даже может быть доступна на `/_raindrops` странице, если добавить специальное [_middleware_](https://bogomips.org/raindrops/Raindrops/Middleware.html) ([пример страницы статистики](https://raindrops-demo.bogomips.org/_raindrops)).

Занятно, но согласно реализованной логике, если _worker_ обработал хотя бы один запрос и затем начал простаивать, то он будет завешен и поднимется новый _worker_ с обнуленным счетчиком, который уже будет игнорироваться этим механизмом ровно до первого входящего запроса. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L498-L517))



#### Обработка сигналов

Управляющие сигналы обрабатываются следующим образом:

`QUIT` - "вежливо" (_graceful_) остановить веб-сервер. _master_ рассылает всем _worker_'ам команды "вежливо" остановиться. Команда передается _worker_'у через заранее открытый _pipe_ - в него просто записывается числовой номер сигнала. Далее с интервалом в 0.1 секунды _master_ повторяет рассылку в течение сконфигурированного _timeout_'а или пока все _worker_'ы не остановятся и подчищает за процессами-зомби (делая системный вызов `waitpid2`). Если по завершению все таки остались какие-то _worker_'ы, их останавливают принудительно посылкой системного сигнала `KILL`. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L340-L354))

Для `TERM` и `INT` процедура аналогичная, но в отличии от "вежливой" остановки, через _pipe_ _master_ отправляет _worker_'ам номер другого сигнала - `TERM` вместо `QUIT`.

`USR1` - переоткрыть файлы логов. Это распространенная практика периодически (например раз в день) архивировать логи приложения. Особенности организации файловых систем Unix'ов позволяют переместить открытый процессом файл в другую директорию не прерываю чтение/запись в него. Но чтобы процесс создал новый файл и начал писать в него, этот файл надо переоткрыть. Чтобы это проходило незаметно для приложения как раз и нужен сигнал `USR1`.

Предполагается следующий сценарий. Файлы логов перемещаются в директорию с архивами. Приложение продолжает писать в эти перемещенные файлы. Далее шлется сигнал `USR1` и Unicorn принудительно переоткрывает все открытые файлы _master_'а и всем _worker_'ам рассылается команда аналогично переоткрыть лог-файлы (команда `USR1`).

Переоткрываются только файлы удовлетворяющие следующим условиям:
- файл открыт на запись ('w') или дозапись ('a')
- или файл уже был перемещен и на его месте создан другой с таким же именем

В последнем случае проверяются _inode number_ открытого файла и файла находящемуся по тому же пути. После этого приложение будет писать в новые файлы с теми же путями ничего не заметив. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/util.rb#L25-L89))

`USR2` - запустить новый _master_ процесс Unicorn'а.

`WINCH` - "вежливо" завершить все процессы _worker_'ы но оставить запущенным _master_. Если используется предзагрузка приложения (выставлена опция `preload_app`), то если нужно _worker_'ы можно моментально запустить послав сигнал `TTIN`. Эта команда обрабатывается только если Unicorn запущен в фоне, иначе она игнорируется. Временно блокируется автоматический запуск новых _worker_'ов, а всем _worker_'ам шлется команда `QUIT`.

`TTIN` - увеличиваем количество _worker_'ов на 1. Фактически новый процесс будет запущен на следующей итерации цикла после засыпания _master_'а в ожидании сигнала. Снимаем блокировку создания новых _worker_'ов если она была выставлена после сигнала `WINCH`.

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

Интересно как выполняется перезагрузка _gem_'ов - Unicorn использует метод `Gem.refresh` из Rubygems. Если приложение снова загружается (опция `preload_app`), то будут подхватываться изменения в его исходном коде.

Если при переоткрытии лог-файлов произошла любая ошибка, то _master_ завершается с кодом 77 (`EX_NOPERM` - "You did not have sufficient permission to perform the operation") следуя [конвенции кодов ошибок](https://man.openbsd.org/sysexits.3)

`CHLD` - этот сигнал посылается операционной системой если завершился один из дочерних процессов. _master_ процесс получает этот сигнал если завершился  _worker_ процесс или новый _master_ при перезапуске. Обработчик просто будит _master_, тот определяет _PID_'ы завершившихся процессов и удаляет ненужную больше информацию о _worker_'ах.



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
- текущая директория может быть изменена (если использовалась символическая ссылка и после деплоя она указывает на директорию с новым релизом),
- Unicorn может быть уже другой версии,
- исходный код приложения тоже может быть обновлен.

В `Kernel#exec` кроме консольной команды передается параметры в виде `Hash` с парами вида `{ fd => socket }`. Это означает перенаправление файлового дескриптора в дочернем процессе на файловый дескриптор в родительском (_redirect to the file descriptor in parent process_). Краткое описание параметров и редиректа можно найти в документации по `Process.spawn` ([Core](https://ruby-doc.org/core-2.6.1/Process.html#method-c-spawn)).

Новый _master_, как было описано выше, возьмет из переменной окружения `UNICORN_FD` числовые дескрипторы унаследованных серверных сокетов и активирует их. Новые _worker_'ы могут сразу же начинать принимать входящие соединения параллельно с _worker_'ами старого _master_'а. Поэтому в `after_fork` _hook_'е, который будет запускаться в процессе _worker_'а при старте, обычно завершают старый _master_ посылая ему системным сигнал `QUIT`.

Если новый _master_ процесс по каким-то причинам завершается, то старый _master_ узнает об этом используя системный вызов `waitpid2` (точно так же как и для завершившихся _worker_ процессов), и откатит сделанные изменения:
- переименует обратно _PID_-файл и
- переименует сам _master_ процесс.

Для проверки существует ли еще новый _master_ используется трюк с `kill 0` - посылается 0-й (несуществующий) сигнала процессу нового _master_'а. Из _man_ страницы по `kill` ([`kill(2)`](http://man7.org/linux/man-pages/man2/kill.2.html)):

> "If sig is 0, then no signal is sent, but existence and permission
> checks are still performed; this can be used to check for the
> existence of a process ID or process group ID that the caller is
> permitted to signal."

Чтобы избежать утечки файловых дескрипторов всем дескрипторам из системного диапазона 3-1024 кроме серверных сокетов выставляется флаг _close-on-exec_ (`FD_CLOEXEC`), чтобы эти дескрипторы были закрыты в дочернем процессе. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L489-L496)).

Ссылки:
* [Fork–exec (Wikipedia)](https://en.wikipedia.org/wiki/Fork%E2%80%93exec)



#### Передача переменной окружения дочернему процессу

Давайте проиллюстрируем это примером на Ruby:

```ruby
# exec.rb

ENV['UNICORN_FD'] = '1'
exec 'ruby puts.rb'
```

```ruby
# puts.rb

if ENV['UNICORN_FD']
  puts "UNICORN_FD = #{ENV['UNICORN_FD']}"
else
  puts 'UNICORN_FD is nil'
end
```

```shell
# shell

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

Команда передается в виде номера системного сигнала и вызывается установленный ранее обработчик для этого сигнала. Чтобы обработчик не был прерван настоящим системным сигналом прием этого сигнала блокируется.

Одновременно может прийти несколько входящих соединений. _worker_ обрабатывает их по очереди и запоминает _timestamp_ начала обработки текущего запроса. Этот _timestemp_ _master_ затем использует, чтобы определить зависание _worker_'а, когда время обработки запроса превысило _timeout_ и завершить процесс.

Далее _worker_ не спешит снова вызывать `IO.select` и ждать входящих соединений. Он думает: - "Раз по текущим сокетам пришли запросы, которые мы уже обработали, наверное, за это время могли прийти и другие запросы на эти сокеты. Надо это проверить." И _worker_ начинает принимать соединения на сокетах, которые были получены в последнем вызове `select`, до тех пор пока соединения не перестанут поступать. Только тогда _worker_ закончит эту итерацию и сделает новый вызов `select`, проверяя соединения на *всех* серверных сокетов. Из этого следует любопытный вывод. Если сервер слушает несколько сокетов, то возможна ситуация, когда некоторые из них будут игнорироваться и ждать пока по другим не перестанут приходить соединения.

Далее _worker_ проверяет не умер ли _master_. Непонятно зачем эта дополнительная проверка нужна ведь _worker_ и так узнает это по закрытию _pipe_'а. Но интересен сам трюк:

```ruby
ppid == Process.ppid or return
```

Здесь сравниваются _PPID_ (_parent process id_) на момент запуска _worker_'a с _PPID_ на текущий момент. На первый взгляд это не имеет смысла, но оказывается, что когда родительский процесс умирает, операционная система изменяет _PPID_ осиротевшего дочернего процесса на _PID_ процесса _init_ (_PID_ 1). На самом деле все намного сложнее и полагаться на магическое число не стоит. Как развернуто [объяснили](https://unix.stackexchange.com/a/177361/16396) на StackExchange это _"implementation-defined process"_. Есть возможность задавать процесс, который "унаследует" осиротевший процесс, так называемый _subreaper_. Если _subreaper_ не задан, то только тогда родителем становится процесс _init_. Это используют супервизоры, такие как systemd и upstart.

Для _pipe_'ов используется обертка `Kgio::Pipe` из _gem_'а [kgio](https://bogomips.org/kgio/). Этот `gem` разработан специально для проекта Unicorn:

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

Unicorn читает только доступные прямо сейчас в сетевом буфере данные (ведь запрос может быть большим и пришла только часть данных) блоками по 16kb ([source](https://github.com/defunkt/unicorn/blob/master/lib/unicorn/http_request.rb#L77-L83)) не дожидаясь пока прийдет весь запрос до конца. На данном этапе главное это распарсить заголовки. Согласно спецификации сокет передается приложению в виде `env['rack.input']` и оно должно дочитать запрос до конца. Парсинг _multipart_ запроса также ложиться на плечи приложения. По спецификации Rack `env['rack.input']` должен поддерживать метод `rewind`, и после его вызова чтение запроса продолжиться сначала. В Unicorn это работает по умолчанию, хотя и может отключаться ради ускорения обработки запросов. Чтобы сделать `rack.input` не- _rewindable_ нужно указать конфигурационную опцию `rewindable_input=false`. По умолчанию при чтении запроса все данные будут сохраняться во временный файл, а когда запрос будет прочитан до конца, все последующие операции чтения будут делаться уже из него. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/tee_input.rb))

Если выставлена конфигурационная опция `check_client_connection`, то перед передачей запроса приложению Unicorn попытается проверить не отвалился ли клиент и не закрыл ли сокет пока его запрос ждал обработки. Согласно документации это сработает только для локального клиента, который запущен на том же компьютере. Статус сокета пытаются определись из его системных опций делая системный вызов `getsockopt` ([`getsockopt(2)`](http://man7.org/linux/man-pages/man2/getsockopt.2.html)). Формат опций специфичен для операционной системы и если не получилось с ними то Unicorn просто пишет начало ответа (строчку "HTTP/1.1 ") ожидая получить ошибку `EPIPE`. Эта будет означать "The local end has been shut down" - т.е. сокет или _pipe_ закрыт на чтение и никто из него уже не прочитает данные.

Unicorn поддерживает [_full socket hijacking_](https://old.blog.phusion.nl/2013/01/23/the-new-rack-socket-hijacking-api/). Это означает, что после того как веб-сервер прочитал и распарсил HTTP запрос и передал его приложению, оно получает прямой доступ к сокету и может реализовать свой произвольный протокол передачи данных свободно читая и записывая данные в сокет. Когда приложение обработало запрос веб-сервер определяет произошел ли _hijacking_ и в этом случае просто закрывает соединение игнорируя заголовки и _body_, которые вернуло приложение. _Socket hijacking_ это часть спецификации Rack и поддерживается всеми Rack-совместимыми веб-серверами кроме WEBrick. Это нашло применение, к примеру, в реализации _websocket_'ов в Rails.

Unicorn обрабатывает код возврата 100 (Continue) особым образом. HTTP протокол по дизайну _statelessness_, т.е. веб-сервер не имеет собственного состояния. Протокол перестает следовать этому принципе в случае с кодом 100. Клиент, предполагая, что сервер может отказаться обрабатывать запрос, может отправить только HTTP заголовки и спросить сервер, будет ли он вообще обрабатывать такой запрос. Если сервер подтверждает это, то клиент шлет _body_ запроса. Это нужно, например, если запрос очень большой. Нет смысла слать весь запрос если сервер по заголовкам может понять, что не будет его обрабатывать. Это работает следующим образом: клиент шлет только заголовки, включая заголовок "Expect: 100-continue”, и ждет ответа от сервера. Сервер должен ответить 417 (Expectation Failed) если не принимает такой запрос и 100 (Continue) если разрешает продолжить. Далее клиент шлет _body_ запроса и сервер возвращает обычный ответ, второй раз.

Именно поэтому если приложение возвращает код ответа 100, то Unicorn игнорирует заголовки и _body_ и отсылает клиенту промежуточный ответ 100 (Continue). Далее он удаляет Expect заголовок из запроса и еще раз вызывает приложение. Затем он проверяет был ли _socket hijacking_ и если нет, то отсылает ответ приложения.

Unicorn также поддерживает _partial socket hijacking_. Это означает, что веб-сервер отправляет заголовки, которые вернуло приложение, но игнорирует _body_. Вместо этого Unicorn предоставляет приложению сокет и оно шлет данные самостоятельно. Предполагается, что это поможет реализовать стриминг приложением. Это реализовано следующим образом: приложение в ответе возвращает заголовок `rack.hijack`, значение которого это Ruby _callable_ объект, который Unicorn вызывает и передает аргументом сокет ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_response.rb#L56)).

В конце кроме закрытия сокета `close` ([`close(2)`](http://man7.org/linux/man-pages/man2/close.2.html)) также делается системный вызов `shutdown` ([`shutdown(2)`](http://man7.org/linux/man-pages/man2/shutdown.2.html)). Согласно комментариям в коде это нужно если само приложение сделало `fork` сокет разделяется родительским и дочерним процессами. И правда, системный вызов `close` закрывает сокет только в текущем процессе, в то время как `shutdown` говорит операционной системе закрыть все копии этого сокета во всех родительских и дочерних процессах.

Ссылки:
* [The new Rack socket hijacking API](https://old.blog.phusion.nl/2013/01/23/the-new-rack-socket-hijacking-api/)
* [Спецификация Rack](https://www.rubydoc.info/github/rack/rack/master/file/SPEC)
* [ Hypertext Transfer Protocol -- HTTP/1.1. Use of the 100 (Continue) Status](https://www.w3.org/Protocols/rfc2616/rfc2616-sec8.html#sec8.2.3)
* [Closing a Socket After Forking](https://www.cs.ait.ac.th/~on/O/oreilly/perl/cookbook/ch17_10.htm)



#### Обработка ошибок

При обработке запроса могут возникать ошибки. Если клиент, например, отвалился, веб-сервер ничего не может сделать и просто прекращает обработку этого запроса. ([source](https://github.com/defunkt/unicorn/blob/v5.5.1/lib/unicorn/http_server.rb#L566-L589))

Если превышена длина _URI_, то возвращается код ошибки 414. Есть и другие ограничения:
* имя заголовка - 256b
* значение заголовка - 80kb
* _URI_ - 15kb
* _path_ - 4kb
* _query string_ - 10kb

Если произошла любая ошибка парсинга запроса, то возвращается код 400.
Если приложением бросается любое исключение, то веб-сервер отдает код 500.

Ссылки:
* [Спецификация Rack](https://www.rubydoc.info/github/rack/rack/master/file/SPEC)
* [Building a Rack Web Server in Ruby](https://ksylvest.com/posts/2016-10-04/building-a-rack-web-server-in-ruby)
* [Rhino, simple Ruby server that can run rack apps](https://github.com/ksylvest/rhino)
* [Ragel State Charts](https://zedshaw.com/archive/ragel-state-charts/)
* [The new Rack socket hijacking API](https://old.blog.phusion.nl/2013/01/23/the-new-rack-socket-hijacking-api/)



### Timeout и время

Когда _master_ определяет зависший _worker_, то ему нужно знать текущее время. Для этого  используется не обычный `Time.now`, а делается специальный системный вызов `clock_gettime` ([`clock_getres(2)`](http://man7.org/linux/man-pages/man3/clock_gettime.3.html)) используя [Ruby обертку](https://ruby-doc.org/core-2.6.1/Process.html#method-c-clock_gettime):

```ruby
Process.clock_gettime(Process::CLOCK_MONOTONIC)
```

Как видно из имени константы `CLOCK_MONOTONIC` будет возвращено монотонное время. Здесь очень важно использовать именно монотонное (т.е. не убывающее) время так как мы сравниваем два `timestamp`'а и определяем разницу между ними. Что будет, если системные часы были переведены назад на 1 минуту вручную или NTP сервисом? Мы получим совершенно некорректную отрицательную разницу там где ожидалась положительная. Это источник очень неприятных багов.

Кстати, монотонное время может даже не быть временем совсем. Или, например, может быть количеством секунд с момента включения компьютера.

Ссылки:
* [Реализация Process.clock_gettime в Ruby](https://github.com/ruby/ruby/blob/v2_6_0/process.c#L7597-L7880)
* [Monotonic Clocks – the Right Way to Determine Elapsed Time](https://www.softwariness.com/articles/monotonic-clocks-windows-and-posix)



### Послесловие

Unicorn это во всех смыслах традиционное Unix приложение. Он активно использует системные вызовы и просто напичкан разными трюками, например:

* демонизация,
* _self-pipe_ трюк,
* определение завершившихся дочерних процессов,
* определение завершения родительского процесса,
* активация сокетов
* поддержка systemd.

Это хороший пример для знакомства как с системными вызовами Unix в общем так и с процессами и синхронизацией между ними в частности.

Давайте перечислим системные вызовы, которые здесь используются:

* `kill` - для отправки _master_'ом сигналов _worker_'у
* `signal`/`sigaction` -  задать обработчик сигнала
* `fork` - для создания нового процесса - _worker_'а или _master_'а
* `exec` - запустить новую программу в текущем процессе
* `setsid` - создать сессию и группу процессов
* `waitpid2` - для получения _PID_ завершившийся дочерних процессов
* `getppid` - получить _PID_ родительского процесса
* `clock_gettime` - получить монотонное время
* `select` - для ожидания входящих соединений или данных в сокетах
* `accept` - для приема нового сетевого соединения
* `getsockopt` - для проверки опций и статуса сокета
* а также открытие/закрытие/чтение/запись в сокет и _pipe_.

Теперь поделюсь личным впечатлением. Не смотря на все достоинства веб-сервера нельзя не отметить некоторую олдскульность проекта. Аскетичный черно-белый сайт с документацией, игнорирование современных инструментов вроде Github/Gitlab, ведение обсуждений в почтовой рассылке. Вместо _pull request_'ов надо слать патчи на почту главному разработчику Eric Wong'у. Это создает некоторый барьер для потенциальный контрибуторов и, вероятно, является одной из основных причин медленного развития проекта (сравните со скоростью разработки Puma'ы). Все это кажется либо слепым подражанием какому-нибудь масштабному проекту вроде Linux kernel либо просто ретроградством.

Что касается самого исходного Ruby-кода, то при его чтении возникло сильное чувство чужеродности. Разработчики практически не использовали богатые возможности синтаксиса Ruby, его коллекции и замыкания. Если внезапно разработчик таки использовал фичу Ruby, то это скорее запутывало код чем делало его яснее и чище. Думаю, если переписать весь код на Си, то в нем мало что изменится - он останется таким же громоздким, плохо структурированным и переусложненным. В целом это неидиоматичный Ruby-код и хорошая иллюстрация как не надо писать на Ruby.



### Ссылки

* [Unicorn homepage](https://bogomips.org/unicorn)
* [Official Git repository](https://bogomips.org/unicorn.git/tree)
* [Unofficial Unicorn Mirror on GitHub](https://github.com/defunkt/unicorn)
* [Thorsten Ball. Unicorn Unix Magic Tricks](https://thorstenball.com/blog/2014/11/20/unicorn-unix-magic-tricks) ([видео](https://www.youtube.com/watch?v=DGhlQomeqKc), [слайды](https://speakerdeck.com/mrnugget/unicorn-unix-magic-tricks))
* [Бах. Архитектура операционной системы Unix](https://blog.heroku.com/unicorn_rails)

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
