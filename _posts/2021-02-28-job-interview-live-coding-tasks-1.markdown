---
layout: post
title:  "Задачка с собеседования #1"
date:   2021-02-28 14:40
categories: Ruby live-coding
---

Правильно провести техническое собеседование - это целое искусство.
Говорят, что если много-много практиковаться то можно достичь
просветления. У меня до сих пор не получилось. Видимо мало практиковал.

Полезно не только собеседование проводить, но и наблюдать со стороны.
Например, ассистировать коллеге или оказаться на противоположной
стороне, когда собеседуют уже тебя.

На техническом собеседовании любят давать практические задачи на
покодить. Сложную задачу давать смысла нет ведь время ограничено.
Тривиальная задачка тоже не подходит, разве что это позиция джуна и
проверяют базовые навыки. Нужна задача, чтобы человек показал не знание
конкретных алгоритмов, а сообразительность и абстракции, которыми он
мыслит. О таких задачах здесь и поговорим.

Я уже давно собираю задачи для собеседований и у меня накопилась целая
коллекция удачных и не очень примеров. Хорошие задачи объединяет
следующее - больше одного решения и задача делится на подзадачи или
этапы. Важен не столько результат, решена задача или нет, а рассуждения
и выбранный подход.


### Задача

Здесь я расскажу о задаче, которую подсмотрел у коллеги. Я ассистировал
на собеседовании и оценивал знания человека по Ruby, а коллега общался
на общие технические темы.

Задача следующая - даны три числа и надо найти сумму квадратов двух
наибольших из них.

Рассмотрим два подхода к решению. Первый из них прямолинейный -
сравнивая числа найти два наибольших (пример на Ruby):

```ruby
def sum_of_largest_two_squared(a, b, c)
  case
    when (a + b) > (b + c) && (a + b) > (a + c)
      a*a + b*b
    when (a + c) > (a + b) && (a + c) > (c + b)
      a*a + c*c
    else
      b*b + c*c
  end
end
```

Вариация этого подхода - найти наименьшее число, а оставшиеся два как
раз и будут наибольшими:

```ruby
def sum_of_largest_two_squared(a, b, c)
  case
  when a < b && a < c
    b*b + c*c
  when b < a && b < c
    a*a + c*c
  else
    a*a + b*b
  end
end
```

Второй подход - это привести задачу к общей и решить используя операции
над коллекциями. Представляем три числа как массив, сортируем по
возрастанию и берем последние два элемента. Это и будут наибольшие
числа:

```ruby
def sum_of_largest_two_squared(a, b, c)
  [a, b, c].sort[-2..-1].map { |i| i*i }.sum
end
```

Такое решение медленнее первого, но короче и нагляднее. Более того,
решается общая задача с N числами. Попробуйте решить первым способом
задачку не с тремя, а с четырьмя числами.


### PS

Давал эту задачку на нескольких собеседованиях и заметил, что выбор
решения не связан напрямую с практическим опытом. Один парень, джуниор,
сразу после университета, решил задачку вторым способом. А опытный
разработчик выбрал первый. Выходит, что эта задачка не абсолютный
критерий и к результату надо относиться осторожно.

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
