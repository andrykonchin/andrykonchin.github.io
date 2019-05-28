---
layout:     post
title:      "Как готовить Bullet в тестах"
date:       2019-05-28 23:17
categories: Rails
---

[Bullet](https://github.com/flyerhzm/bullet) это Ruby-гем для детектирования проблемы N+1 SELECT запросов к базе данных. В данный момент поддерживаются Active Record и Mongoid ORM'ы. Bullet весьма популярен и это фактически безальтернативное решение для Rails веб-приложения.

Принцип его работы простой. Bullet встраивается в процесс обработки HTTP запросов (добавляет _Rack middleware_) и процесс обработки _Active Job_ задач (регистрирует `around` _hook_). В начале обработки HTTP запроса или отложенной задачи активируется детектирование N+1 запросов. Если проблема обнаружена, то Bullet может выполнить следующие действия:

* логировать это в файл
* бросить исключение
* послать уведомление в один из поддерживаемых сервисов (например, Airbrake или Honeybadger) или
* отправить сообщение в Slack или Jabber.

Мы давно используем Bullet в текущем проекте и проблемы N+1 запросов обнаруживаются еще на этапе прохождения тестов на CI и локально. Если при прохождении теста найдена N+1 проблема, то Bullet бросает исключение и тест считается упавшим. Таким образом имея хорошее тестовое покрытие и полагаясь на Bullet мы можем быть уверены в отсутствии N+1 запросов.


#### Проблема применения в тестах

Однажды внося изменения в batch обработку большого объема данных, которые читаются из базы данных, я наткнулся на очевидный N+1 SELECT запрос. Вместо 30-40 запросов в лог попало ~1000 однотипных SQL запросов и выполнение _batch_’а занимало 5-10 минут вместо ожидаемых 2-5 секунд. Я решил, что, вероятно, этот компонент просто плохо покрыт тестами раз Bullet не обнаружил эту проблему. Но тесты оказались на месте. Затем я решил, что проблема в том, что в тестах в _batch_ попадала всего одна запись из таблицы, и поэтому собственно никаких N+1 запросов не было. Тест с несколькими записями в _batch_'е был написан и, к моему удивлению, успешно прошел. Bullet опять не среагировал на уже явные N+1 запросы.

Здесь стало понятно, что черная магия Bullet’а не всегда срабатывает и часть N+1 запросов все это время оставалась незамеченной. На моей памяти Bullet реагировал на N+1 в новом коде и действительно обнаруживал проблемы. Но вот что ему мешало реагировать в других случаях оставалось непонятно.

Пролистав Issues на Github’е я обнаружил описание [точно такого же случая](https://github.com/flyerhzm/bullet/issues/427) - Bullet не детектировал явный N+1 запрос в тестах. В комментариях объяснили, что

> Bullet apparently ignores items that have been created after Bullet.start_request was issued, marking them as ‘impossible'

и описание подключение Bullet в RSpec тестах в Readme просто некорректно. Таким образом из-за особенностей реализации Bullet все модели созданные после включения Bullet’а (вызова `Bullet.start_request`) игнорируются.

Как описано в [Readme](https://github.com/flyerhzm/bullet/blob/57c3b80b2d4e68bdb648411ae8f2334d9036fa8c/README.md) текущей на данный версии (6.0.0) Bullet в тестах подключается следующим образом:

```ruby
# spec/rails_helper.rb
if Bullet.enable?
  config.before(:each) do
    Bullet.start_request
  end

  config.after(:each) do
    Bullet.perform_out_of_channel_notifications if Bullet.notification?
    Bullet.end_request
  end
end
```

RSpec в своей  документации явно не декларирует порядок выполнения `before` _hook_’ов, но фактически они отрабатывают в порядке объявления. Вначале выполняются _hook_'и из `spec_helper.rb`/`rails_helper.rb`/`spec/support/*` и затем уже объявленные в самом файле с тестом от внешнего `describe` опускаясь к самому тесту.

Поскольку `Bullet.start_request` вызывается в `before` _hook_'e определенном в `rails_helper.rb`, он становится самым первым `before` _hook_'ом и все модели будут создаваться и сохраняться в базу после него, а следовательно игнорироваться.

Давайте проиллюстрируем это поведение примером:

```ruby
describe 'Bullet N+1 detector' do
  it 'detects issue' do
    account = create :account
    create :order, account: account
    create :order, account: account

    expect do
      Bullet.profile do
        Order.all.map(&:account)
      end
    end.to raise_error(
      Bullet::Notification::UnoptimizedQueryError,
      /USE eager loading detected/
    )
  end

  it 'does not detect issue' do
    account = create :account

    expect do
      Bullet.profile do
        create :order, account: account
        create :order, account: account

        Order.all.map(&:account)
      end
    end.not_to raise_error
  end
end
```

В первом тесте ордера создаются до запуска Bullet и он успешно обнаруживает N+1. Во втором случае ордера создаются после и Bullet уже не обнаруживает проблему. Здесь используется метод `Bullet.profile`, который аналогичен вызову `Bullet.start_request`, выполнению блока и вызову `Bullet.end_request`.

#### Как использовать Bullet в тестах

Очевидно, что единственный надежный способ детектировать N+1 запросы (в модульных тестах) это явное использование `Bullet.profile` в тесте. К примеру, в `controller` или `request` тестах можно создать отдельный тест на каждый _action_ с явным использованием Bullet:

```ruby
it 'does not cause N+1 problem' do
  # create necessary backgroud in database

  Bullet.profile do
    get :index
  end
end
```

Так же очевидно, что эта проблема не касается End-to-End тестов. В Capybara сценариях и Rails system тестах вовлекаются Rack middleware и срабатывает штатная интеграция Bullet’а.

#### Как работает N+1 детектор в Bullet

Давайте разберемся почему Bullet работает таким образом и что это за _impossible_ объекты, упомянутые в issue.

Bullet поддерживает debug режим, в котором логирует действия детектора. Если запустить первый тест, в котором Bullet успешно отработал и обнаружил N+1, в _debug_ режиме (выставив переменную окружения `BULLET_DEBUG=true`), то мы увидим следующие сообщения в консоле:

<pre>
[Bullet][Detector::NPlusOneQuery#add_possible_objects] objects: Order:1, Order:2
[Bullet][Detector::NPlusOneQuery#add_possible_objects] objects: Order:1, Order:2
[Bullet][Detector::NPlusOneQuery#add_impossible_object] object: Account:1
[Bullet][Detector::NPlusOneQuery#add_impossible_object] object: Account:1
[Bullet][Detector::Association#add_call_object_associations] object: Order:1, associations: account
[Bullet][Detector::NPlusOneQuery#call_association] object: Order:1, associations: account
[Bullet][detect n + 1 query] object: Order:1, associations: account
[Bullet][Detector::NPlusOneQuery#add_possible_objects] objects: Account:1
[Bullet][Detector::NPlusOneQuery#add_impossible_object] object: Account:1
[Bullet][Detector::NPlusOneQuery#add_impossible_object] object: Account:1
[Bullet][Detector::Association#add_call_object_associations] object: Order:2, associations: account
[Bullet][Detector::NPlusOneQuery#call_association] object: Order:2, associations: account
[Bullet][detect n + 1 query] object: Order:2, associations: account
[Bullet][Detector::NPlusOneQuery#add_possible_objects] objects: Account:1
</pre>

Обратите внимание на `add_possible_objects`  и `add_impossible_object` сообщения. Bullet отслеживает модели, которые могут привести к N+1 (_possible_), и модели, которые не могут (_impossible_). Если мы загружаем ассоциацию (в данном случае Order `belongs to` Account) на _possible_ модели это автоматически означает N+1 запрос.

Bullet помечает модель как _possible_ в следующих случаях:
* Загружено несколько моделей через `.find` или `.find_by_sql` вызовы
* Загружено несколько моделей через _collection_ ассоциацию
* Загружена модель через _singular_ ассоциацию на _possible_ модели

Соответственно Bullet помечает модель как _impossible_ в следующих случаях:
* Создана и сохранена новая модель
* Загружена только одна модель через `.find` или `.find_by_sql` вызовы
* Загружена только одна модель через _collection_ ассоциацию
* Загружена только одна модель через _singular_ ассоциацию на _impossible_ модели

Нужно отметить, что модель может быть отмечена одновременно и как _possible_ и как _impossible_.

Как видно в отладочном выводе модели `Order:1` и `Order:2` помечаются как _possible_ модель. Под капотом `Order.all` выполняется вызов `.find_by_sql` и загруженные модели должны пометиться как _possible_. Далее загружается ассоциированная модель `Account:1`. Загрузилась всего одна модель - поэтому она помечается как _impossible_. Модель `Order:1` помечена как _possible_ и не помечена как _impossible_. Как следствие при обращении к ассоциации `account` (как и к любой другой) на ордере `Order:1` детектируется N+1 запрос:

<pre>
[Bullet][detect n + 1 query] object: Order:1, associations: account
</pre>

Рассмотрим второй тест и его отладочный вывод:

<pre>
[Bullet][Detector::NPlusOneQuery#add_impossible_object] object: Order:3
[Bullet][Detector::NPlusOneQuery#add_impossible_object] object: Order:4
[Bullet][Detector::NPlusOneQuery#add_possible_objects] objects: Order:3, Order:4
[Bullet][Detector::NPlusOneQuery#add_possible_objects] objects: Order:3, Order:4
[Bullet][Detector::NPlusOneQuery#add_impossible_object] object: Account:2
[Bullet][Detector::NPlusOneQuery#add_impossible_object] object: Account:2
[Bullet][Detector::Association#add_call_object_associations] object: Order:3, associations: account
[Bullet][Detector::NPlusOneQuery#call_association] object: Order:3, associations: account
[Bullet][Detector::NPlusOneQuery#add_impossible_object] object: Account:2
[Bullet][Detector::NPlusOneQuery#add_impossible_object] object: Account:2
[Bullet][Detector::NPlusOneQuery#add_impossible_object] object: Account:2
[Bullet][Detector::Association#add_call_object_associations] object: Order:4, associations: account
[Bullet][Detector::NPlusOneQuery#call_association] object: Order:4, associations: account
[Bullet][Detector::NPlusOneQuery#add_impossible_object] object: Account:2
</pre>

Можно заметить, что оба ордера (`Order:3` и `Order:4`) помечены как _impossible_, т.к. они были созданы и сохранены, и одновременно как _possible_, т.к. они были загружены из базы одновременно. Как мы видим далее обращение к ассоциации `account` не детектируется как N+1. В отличие от предыдущего пример модель `Order:3` помечена одновременно и как _possible_ и как _impossible_.

Чтобы считать обращение к ассоциации N+1 проблемой должно выполниться следующее условие - модель (на которой обращаются к ассоциации) является _possible_ и не является _impossible_. Это условие выполняется для первого теста и не выполняется для второго.


#### Залючение

Bullet это прекрасный пример магического черного ящика. Все
замечательно пока он работает как ожидалось, и все становится сильно
сложнее, когда он перестает. Реализация Bullet'а весьма запутанна -
он тесно внедряется в ActiveRecord и monkey-patch'ит приватные методы
и классы. Проверить корректность этого достаточно нетривиально - для
этого надо хорошо разобраться в реализации самого ActiveRecord, а это самая
сложная часть Rails.

Можно сделать очевидный вывод, что для срабатывания N+1 детектора обязательно воссоздавать настоящую ситуацию с N+1 запросами. Имеется в виду, что надо создавать в бэкграунде теста множество моделей и заполнять их ассоциации - одной модели ордера в приведенном примере не достаточно. Не важно как много моделей в ассоциации, но ордеров должно быть несколько.

Bullet не ограничивается детектированием N+1 запросов. Он может находить пропущенные и наоборот избыточные eager loading, а так же рекомендовать кеширование counter'ов.

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
