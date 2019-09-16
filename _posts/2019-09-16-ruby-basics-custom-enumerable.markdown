---
layout:     post
title:      "Как создать Enumerable-коллекцию"
date:       2019-09-16 23:39
categories: Ruby
---

Когда работаешь со внешними источниками данных - файлом, HTTP API или базой
данных, иногда удобно от него абстрагироваться и работать с данными как с
ленивой _Enumerable_-коллекцией, скрывая детали реализации - механизмы
загрузки или парсинга данных. Ведь хочется простоты и абстракций.

Возьмем, например, внешний HTTP API. Сервисы вроде Facebook любят отдавать
данные постранично. Приходится писать простой но объемный код для загрузки этих
страниц, проверки признака завершения итд. Страничная природа данных может
проникнуть с нижнего уровня HTTP-запросов на самый верх. Абстракция ленивой
_Enumerable_-коллекции так и напрашивается сама собой.

Или рассмотрим другой пример - работа с большими CSV/XML файлами. Вместо
того, чтобы загрузить в память и распарсить сразу весь файл, его можно
обрабатывать по частям (строчкам или узлам) потребляя значительно меньше
памяти.

Давайте разберем это на примере парсинга большого CSV-файла.

### Парсим CSV-файл

> Disclaimer: Есть уже готовый метод `CSV#each`, который отвечает всем
> нашим требованиям. Поэтому на практике можно и нужно использовать именно
> его.

Можно пойти простым путем и загрузить весь файл в память:
```ruby
CSV.read('data.csv', headers: true)
```

На файле в 12 МБ у меня это занимает 4.3 секунды и 265 МБ оперативной
памяти (бралась разница между объемом памяти Ruby-процесса до и после
парсинга). Очевидно, что пиковое значение могло быть и больше ведь
результат искажается работой сборщика мусора. Если его отключить, то
потребление памяти выростает до 566 МБ.

Посмотрим как можно лениво парсить CSV-файл обрабатывая по одной строчке
за раз:

```ruby
File.open('data.csv', 'r') do |file|
  csv = CSV.new(file, headers: true)

  while row = csv.shift
    puts row
  end
end
```

Каждый раз вызывая метод `shift` мы загружаем из файла и парсим
очередную строчку CSV-файла. Это занимает такое же время - 4.4
секунды, но потребляет всего 24 МБ.

### Способ #1 - подключить модуль Enumerable

Это классический подход - создать новый класс и подмешать в него модуль
`Enumerable`:

```ruby
class LazyCSVCollection
  include Enumerable

  def initialize(path, options = nil)
    @path = path
    @options = options || {}
  end

  def each
    File.open(@path, 'r') do |file|
      csv = CSV.new(file, @options)

      while row = csv.shift
        yield row
      end
    end
  end
end
```
```ruby
seq = LazyCSVCollection.new('data.csv', headers: true)
seq.map { |r| r.to_h }
```

### Способ #2 - создать новый enumerator

В самом деле, класс `Enumerator` уже подмешивает в себя `Enumerable` и
создать _enumerable_ можно разными способами. Один из них - использовать
конструктор `Enumerator.new`. Это даже проще чем первый вариант - можно
обойтись без нового класса:

```ruby
seq = Enumerator.new do |y|
  File.open('data.csv', 'r') do |file|
    csv = CSV.new(file, headers: true)

    while row = csv.shift
      y << row
    end
  end
end

seq.map { |r| r.to_h }
```

### Способ #3 - использовать `Object#to_enum`

Возможно, уже есть подходящий метод-итератор, который принимает блок но, к
сожалению, не возвращает _enumerator_. Остается только превратить
метод-итератор в объект-*enumerator*. Для этого нам пригодится метод
`to_enum`.

В случае с CSV нам подходит метод `CSV.foreach`, который принимает блок
и проходится по строчкам файла:

```ruby
CSV.foreach('data.csv', headers: true) do |row|
  puts row.to_h
end
```

Чтобы получить _enumerator_, достаточно сделать следующее:

```ruby
seq = CSV.to_enum(:foreach, 'data.csv', headers: true)
seq.map { |r| r.to_h }
```

Метод с `foreach` аналогичен варианту с `CSV#each` но немного удобнее,
ведь теперь не надо открывать и закрывать файл вручную. Кстати,
потребляется еще меньше памяти - 13 мб.


### Ссылки

* [Stop including Enumerable, return Enumerator instead](https://blog.arkency.com/2014/01/ruby-to-enum-for-enumerator/)
* [Processing large CSV files with Ruby](https://dalibornasevic.com/posts/68-processing-large-csv-files-with-ruby)

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com


