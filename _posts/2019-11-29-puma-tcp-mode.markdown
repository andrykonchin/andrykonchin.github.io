---
layout:     post
title:      "Превращаем Puma в TCP-сервер"
date:       2019-11-29 22:59
categories: Ruby
---

[Puma](https://puma.io/) это один из трех популярных веб-серверов на
Ruby (еще можно упомянуть Unicorn и Thin). Одновременно с этим ее
документация сильно оставляет желать лучшего. Многие возможности не
документированы, малоизвестны и нужно нырять в исходники, чтобы
разобраться как с этим работать. Одна из таких возможностей - это запуск
Puma в режиме TCP-сервера. Об этом я и расскажу подробнее в это заметке.


### TCP-сервер

В TCP-режиме Puma обрабатывает не HTTP-запросы, а входящие
TCP-соединения давая приложению к ним полный доступ.

TCP-сервер - это такой компонент, который умеет обрабатывать входящие
сетевые соединения по протоколу TCP. TCP и UDP - это самые
распространенные современные протоколы транспортного уровня. Большая
часть данных в мире передается именно по этим двум протоколам.
Поэтому TCP-сервер это неотъемлемая часть серверов для практически
любого сетевого протокола - HTTP, FTP, DNS, SMTP...

Простейший TCP-сервер на Ruby может выглядеть следующим образом:

```ruby
require 'socket'

server = TCPServer.new 2000 # Server bind to port 2000
loop do
  client = server.accept    # Wait for a client to connect
  client.puts "Hello !"
  client.puts "Time is #{Time.now}"
  client.close
end
```

(пример из [документации](https://ruby-doc.org/stdlib-2.5.1/libdoc/socket/rdoc/TCPServer.html))

Здесь мы создаем серверный сокет, который слушает входящие соединения на
порту 2000. Установив соединение, сервер пишет приветствие, текущее
время и закрывает соединение.

Примерно так же работает и NTP-сервер (сервер синхронизации часов
компьютером по сети), только там используют протокол UDP.


### Конфигурация TCP-режима в Puma

Чтобы перевести Puma в этот режим надо задать опцию `tcp_mode`, IP и
порт, на которых нужно запустить сервер. Это делается либо через опции
командной строки:

```shell
$ puma --tcp-mode --bind tcp://127.0.0.1:9292
```

либо в конфиг-файле:

```ruby
# config/puma.rb
tcp_mode
bind 'tcp://0.0.0.0:9292'
```

Приложение, которое будет обрабатывать входящие соединения, задается в
конфиг-файле следующим образом:

```ruby
# config/puma.rb
app do |env, socket|
  # ...
end
```


### Пример с эхо-сервером

Рассмотрим самый простой пример с эхо-сервером (из
[документации](https://github.com/puma/puma/blob/master/docs/tcp_mode.md)),
который читает данные, отправленные клиентом, и шлет их клиенту обратно
в ответ:

```ruby
# config/puma.rb
app do |env, socket|
  s = socket.gets
  socket.puts "Echo #{s}"
end
```

Запустим Puma следующей командой

```shell
$ puma —-config config/puma.rb
```

Где в `config/puma.rb` находится приведенная выше конфигурация:

```ruby
tcp_mode
bind 'tcp://0.0.0.0:9292'

app do |env, socket|
  s = socket.gets
  socket.puts "Echo #{s}"
end
```

Давайте проверим работу нашего сервера и отошлем ему несколько строчек
через `telnet`. Telnet открывает TCP-соединение и шлет введенные в консоли
данные по сети.

```shell
$ telnet 0.0.0.0 9292
Trying 0.0.0.0...
Connected to 0.0.0.0.
Escape character is '^]'.
foo
Echo foo
^CConnection closed by foreign host.
```

Мы видим, что в ответ на сообщение `foo` сервер, как и ожидалось, ответил `Echo foo`.


### Пример с удаленным shell

Давайте рассмотрим более сложный пример и сделаем что-то полезное. Мы
сделаем упрощенный вариант SSH/RSH - подключившись к нашему серверу
клиент сможет удаленно выполнять _shell_-команды.

Наше приложение будет принимать TCP-соединение, читать команды,
выполнять их в _shell_ и писать клиенту в ответ результат.

Реализация не сильно отличается от эхо-сервера. Создадим следующий
конфиг-файл:

```ruby
# config.rb
require_relative 'puma_shell'

tcp_mode
bind 'tcp://127.0.0.1:9292'
threads 2, 10

app do |env, socket|
  PumaShell.run(env, socket)
end
```

В отличии от предыдущего примера мы явно задаем верхний лимит
количества потоков - 10. Поэтому сервер может параллельно обрабатывать
10 соединений, т.е. держать одновременно 10 клиентских сессий.

Упрощенно приложение делает следующее:

```
вывести приветствие

пока не пришла команда quit/exit
  прочитать очередную команду из сокета
  выполнить ее в shell
  написать stdout+stderr команды обратно в сокет

попрощаться
```

В начале каждой сессии приложение выводит приветствие "You are welcome
to Puma Shell" и приглашение для ввода команды ">". Затем в режиме REPL
читает команду, выполняет ее в _shell_ и записывает клиенту _stdout_ и
_stderr_ команды. Далее ждет новую команду. Когда пользователь вводит
`exit` или `quit`, приложение завершает сессию.

Само приложение вынесено в отдельный файл и выглядит следующим образом:

```ruby
# puma_shell.rb
require 'open3'

class PumaShell
  def self.run(env, socket)
    socket.puts "You are welcome to Puma Shell"

    loop do
      socket.write "> "
      command = socket.gets.chomp

      next if command.empty?
      break if ['exit', 'quit'].include? command

      # Use trick with adding ';' to force Ruby to use shell
      # instead of passing command to the OS directly.
      # It's important for error handling.
      command = command + ';'

      Open3.popen2e(command) do |stdin, stdout_and_stderr, thr|
        output = stdout_and_stderr.read.chomp
        socket.puts output
      end
    end

    socket.puts "Bye!"
  end
end
```

Давайте запустим сервер и немного поиграем с ним.

Стартуем сервер следующей командой:

```shell
$ puma --config config.rb

Puma starting in single mode...
* Version 4.3.0 (ruby 2.6.5-p114), codename: Mysterious Traveller
* Min threads: 2, max threads: 10
* Environment: development
* Mode: Lopez Express (tcp)
* Listening on tcp://127.0.0.1:9292
Use Ctrl-C to stop
```

Как видим, сервер запустился в TCP-режиме ("Mode: Lopez Express (tcp)"),
количество потоков - от 2 до 10 и сервер слушает порт 9292 на сетевом
интерфейсе 127.0.0.1, как мы и настроили в конфиг-файле.

Попробуем подключиться к серверу `telnet`'ом:

```shell
$ telnet 127.0.0.1 9292

Trying 127.0.0.1...
Connected to localhost.
Escape character is '^]'.
You are welcome to Puma Shell
```

Здесь началась новая сессия и сервер вывел "You are welcome to Puma
Shell". Продолжим сессию и выполним несколько команд:

```shell
> uname
Darwin
> pwd
/Users/andrykonchin/projects/andrykonchin.github.io/artifacts
> ls -la
total 24
drwxr-xr-x  5 andrykonchin  staff  160 Nov 23 14:37 .
drwxr-xr-x  9 andrykonchin  staff  288 Nov 23 02:05 ..
-rw-r--r--  1 andrykonchin  staff   73 Nov 23 02:06 Gemfile
-rw-r--r--  1 andrykonchin  staff  163 Nov 23 02:06 Gemfile.lock
-rw-r--r--  1 andrykonchin  staff  658 Nov 23 14:37 config.rb
> foobar
sh: foobar: command not found
> quit
Bye!
Connection closed by foreign host.
```

Видим, что сервер выполняет команды от имени текущего пользователя и в
текущей директории. Если произошла ошибка и что-то вывелось в _stderr_,
это сообщение тоже передается клиенту:

```shell
> foobar
sh: foobar: command not found
```

При завершении сессии сервер прощается и пишет "Bye!".

Этот пример все еще игрушечный и его нельзя использовать в _production_.
Здесь не хватает аутентификации и шифрования данных. Чтобы поддерживать
большую нагрузку и много клиентов одновременно лучше заменить
многопоточную модель на асинхронную обработку запросов (_event-loop_,
_user-space threads_ или аналогичные модели конкурентности).

С другой стороны мы дешево и сердито получили рабочее приложение,
разработка которого с нуля могла бы занять несколько дней.


### А зачем?

Это вполне логичный вопрос. Зачем использовать для разработки
TCP-сервера веб-сервер? Ведь это как микроскопом забивать гвозди.

Давайте перечислим, что нам дает использование Puma:

* в Puma'е реализована многопоточность (_thread pool_ и _reactor_)
* Puma'у можно запускать в _claster_-режиме, когда поднимается несколько
  системных процессов, чтобы лучше масштабироваться по ядрам процессора
* Puma поддерживает два способа управления сервером - через системные
  сигналы и через CLI утилиту `pumactl`
* Puma интегрируется с systemd - наследует файловые дескрипторы
(серверные сокеты) используя переменные окружения `LISTEN_FDS` и
`LISTEN_PID`, которые выставляет systemd
* Puma собирает статистику обработанных запросов, которая доступны через
  `pumactl`


### PS

Идея написать эту заметки пришла ко мне, когда в рамках Hacktoberfest я
работал над документацией Puma
([PR](https://github.com/puma/puma/pull/2045)).


> Сноска для любознательных.
> Реализацию TCP-режима можно посмотреть здесь - <https://github.com/puma/puma/blob/v4.3.0/lib/puma/server.rb#L177-L202>


### Ссылки

* <https://puma.io/>
* <https://github.com/puma/puma/blob/v4.3.0/docs/tcp_mode.md>
* <https://ruby-doc.org/stdlib-2.6/libdoc/socket/rdoc/TCPSocket.html>
* <https://stackoverflow.com/a/7263556/219594>
