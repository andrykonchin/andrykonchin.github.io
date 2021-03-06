---
layout: post
title:  "Задачка с собеседования #2"
date:   2021-03-06 20:40
categories: Ruby live-coding
---

Продолжаем серию задач с собеседований. Следующую задачу мне предложили решить на
одном из уже моих собеседований. Запомнилась тем, что несколько раз уточняли
условие, и это сильно усложнило начальное решение. Не помню уже в
точности всех деталей и вопросов, поэтому опишу более полное решение,
чем то, что получилось у меня тогда.

Итак, задачка такая - надо реализовать метод `reduce` из модуля
Enumerable в Ruby
([documentation](https://ruby-doc.org/core-3.0.0/Enumerable.html#method-i-reduce)).


### Первая итерация

Я помнил сигнатуру вызова:

```ruby
[1, 2, 3].reduce(0) { |acc, el| acc + el }
```

Методу передают начальное значение аккумулятора и блок, который
возвращает новое значение аккумулятора.

Получилось вот такое наивное решение:

```ruby
class Array
  def my_reduce(init_value, &block)
    acc = init_value

    each do |el|
      acc = block.call(acc, el)
    end

    acc
  end
end
```

Переоткрываем класс `Array`, добавляем новый метод и используем метод
`each`, чтобы перебрать элементы массива.


### Вторая итерация

Уточним, что `reduce` также принимает вместо блока имя метода, который
будет вызываться на объекте-аккумуляторе:

```ruby
[1, 2, 3].my_reduce(0, :+)
```

Хорошо, добавляем еще один аргумент и вызываем метод если его передали
вместо блока:

```ruby
class Array
  def my_reduce(init_value, method_name = nil, &block)
    acc = init_value

    each do |el|
      acc = if method_name
              acc.send(method_name, el)
            else
              block.call(acc, el)
            end
    end

    acc
  end
end
```


### Третья итерация

Дальше поправим, что начальное значение необязательно и можно вызвать
`reduce` без него.

Наивно делаем вот так:

```ruby
def my_reduce(init_value = nil, method_name = nil, &block)
  acc = init_value || 0
```

Далее спрашиваем, а если массив не чисел, а, к примеру, строк?

Хорошо, в этом случае берем начальным значением первый элемент массива:

```ruby
acc = init_value || first
```

И начинаем теперь не с первого элемента, а со второго:

```ruby
index_to_start = init_value ? 0 : 1
# ...
self[index_to_start..-1].each do |el|
  # ...
end
```

Уже лучше. Но теперь у метода два опциональных параметра `init_value` и
`method_name`. И не понятно как их различить если передали только один
из них. Это может быть и начальное значение и имя метода:

```ruby
[1, 2, 3].my_reduce(:+)
[1, 2, 3].reduce(0) { |acc, el| acc + el }
```

В обоих случаях значение прийдет как параметр `init_value`, а
`method_name` останется `nil`.

Опираемся на наличие или отсутствие блока. Если блока нет - значит
передали `method_name`. Если блок есть - трактуем единственный аргумент
как начальное значение:

```ruby
def my_reduce(a = nil, b = nil, &block)
  if block
    init_value = a
    method_name = nil
  else
    if b != nil
      init_value = a
      method_name = b
    else
      init_value = nil
      method_name = a
    end
  end
  # ...
end
```


### Четвертая итерация

А что будет, если передать `nil` как начальное значение? Код отработает
будто начальное значение не задано. Используем как дефолтное значение
аргументов не `nil`, а другое значение. То, что пользователь не
передаст:

```ruby
class Array
  NOT_SPECIIED = Object.new

  def my_reduce(init_value = NOT_SPECIIED, method_name = NOT_SPECIIED, &block)
    # ...
  end
end
```


### Итоговое решение

В конце концов из-за разных способов вызова `reduce` решение распухло и
стало громоздким:

```ruby
class Array
  NOT_SPECIIED = Object.new

  def my_reduce(a = NOT_SPECIIED, b = NOT_SPECIIED, &block)
    if block
      init_value = a
      method_name = NOT_SPECIIED
    else
      if b != NOT_SPECIIED
        init_value = a
        method_name = b
      else
        init_value = NOT_SPECIIED
        method_name = a
      end
    end

    acc = init_value != NOT_SPECIIED ? init_value : first
    index_to_start = init_value != NOT_SPECIIED ? 0 : 1


    self[index_to_start..-1].each do |el|
      acc = if method_name != NOT_SPECIIED
              acc.send(method_name, el)
            else
              block.call(acc, el)
            end
    end

    acc
  end
end
```

Остался один нерешенный вопрос с оптимальностью выражения
`self[index_to_start..-1].each`. Здесь создается новый массив и значит
будут накладные расходы по памяти. Это решается добавлением еще пары
строчек кода в блок метода `each` и пропуском первого элемента, если
используем его как начальное значение.


### Альтернативная реализация

Любопытно посмотреть на реализации метода `reduce` в Ruby. Нашел
[вариант на
Ruby](https://github.com/rubinius/rubinius/blob/master/core/enumerable.rb#L370-L403)
в исходниках Rubinius (в MRI реализация на Си):

```ruby
def inject(initial=undefined, sym=undefined)
  if !block_given? or !undefined.equal?(sym)
    if undefined.equal?(sym)
      sym = initial
      initial = undefined
    end

    # Do the sym version

    sym = sym.to_sym

    each do
      element = Rubinius.single_block_arg
      if undefined.equal? initial
        initial = element
      else
        initial = initial.__send__(sym, element)
      end
    end

    # Block version
  else
    each do
      element = Rubinius.single_block_arg
      if undefined.equal? initial
        initial = element
      else
        initial = yield(initial, element)
      end
    end
  end

  undefined.equal?(initial) ? nil : initial
end
```


### PS

Мне понравилась эта задачка. Ее можно постепенно усложнять и определить,
на какой итерации человек потеряется. Минус в том, что решение займет
много времени. Я решал не меньше получаса.

Я люблю задачки на реализовать что-нибудь из стандартной библиотеки. В
следующий раз на собеседовании предложу какой-нибудь метод из `Array`,
`Enumerable` или даже `Enumerator::Lazy`.

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
