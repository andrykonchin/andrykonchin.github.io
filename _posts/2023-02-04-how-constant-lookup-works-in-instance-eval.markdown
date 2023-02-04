---
layout: post
title:  Как работает constant lookup в `#instance_eval`
date:   2023-02-04 15:10
categories: Ruby
---

Недавно плотно позанимался с методом `BasicObject#instance_eval`
(полезный для построение DSL-ей в Ruby) и сделал для себя парочку
открытий.

У меня создалось впечатление, что вместо принципа "наименьшего сюрприза"
разработчики здесь использовали подход "а давайте всех удивим" или
"пусть никто не догадается, как это работает". Особенно меня порадовало,
как работает поиск констант в коде, который выполняется
`#instance_eval`'ом. Не нашел ничего об этом в документации да и в
интернете ничего путного не нагуглилось. Поэтому опишу здесь как
`#instance_eval`, и особенно _constant lookup_, работает. Уточню, что
речь идет о Ruby 3.1.



### Что мы знаем об `#instance_eval`

Давайте вспомним, как `#instance_eval` должен работать. Согласно
[документации](https://ruby-doc.org/core-3.1.1/BasicObject.html#method-i-instance_eval)
`#instance_eval` выполняет код в _контексте_ объекта, а именно:
* подменяет _self_ - теперь это сам объект - и
* дает доступ к _instance variables_ объекта

Также можно вызывать методы объекта, в том числе приватные, не указывая
_receiver_'а.

```ruby
class KlassWithSecret
  def initialize
    @secret = 99
  end

  private

  def the_secret
    "Ssssh! The secret is #{@secret}."
  end
end

k = KlassWithSecret.new

k.instance_eval { @secret }          #=> 99
k.instance_eval { the_secret }       #=> "Ssssh! The secret is 99."
k.instance_eval {|obj| obj == self } #=> true
```

Метод `#instance_eval` принимает:
* блок
* или строчку кода

```ruby
k.instance_eval "@secret"          #=> 99
k.instance_eval "the_secret"       #=> "Ssssh! The secret is 99."
```

Блок выполняется в контексте, где он определен, - это обычное поведение
блока как замыкания. То есть все кроме _self_ и _instance variables_
приходит из этого контекста - а это константы, локальные переменные и
_class variables_.

В отличие от блока, строка с кодом не привязана сама по себе к
конкретному месту в коде, объекту или классу. И ожидаемо, она
выполняется в контексте, где вызван сам метод `#instance_eval` (т.е то
место, где стоит вызов `obj.instance_eval(...)`).



### Class variables lookup

С _class variables_ все просто - _class variable lookup_ прямолинейно
проходится по иерархии классов объекта, где вызван `#instance_eval`
(_caller_). Именно _caller_'а, а не _receiver_'а. Помним же, что от
_receiver_'а приходят только _self_ и _instance variables_. Поэтому
остается только _caller_.

В следующем примере _class variable_ находится в родительском классе
вызывающего объекта:

```ruby
class A
  @@foo = "class variable in class A"
end

class B < A
  def get_class_variable
    "".instance_eval "@@foo"
  end
end

B.new.get_class_variable #  => "class variable in class A"
```

А вот с константами все сложнее.



### Constant lookup

Напомню логику _constant lookup_ в Ruby:
* Ruby начинает искать константу в текущем _lexical scope_ (классе или
модуле)
* если не находит - тогда проверяет внешние _lexical scope_'ы.

```ruby
module A
  FOO = 'I am defined in module A'

  module B
    module C
      def self.get_constant
        FOO
      end
    end
  end
end

A::B::C.get_constant # => "I am defined in module A"
```

Далее Ruby ищет константу в иерархии наследования - проверяет текущий
класс, затем родительский класс итд до `Object` и `BasicObject`.

```ruby
class A
  FOO = 'I am defined in class A'
end

class B < A
  def get_constant
    FOO
  end
end

B.new.get_constant # => "I am defined in class A"
```



### Constant lookup в `#instance_eval`

Если `#instance_eval` вызван с блоком - константы ищутся в контексте,
где определен блок. Но когда `#instance_eval` вызван со строкой... Здесь
и начинается самое интересное.

```ruby
object.instance_eval("FOO")
```

В случае с `#instance_eval` возникает неоднозначность - появляются два
потенциальных источника констант - вызывающий объект (_caller_) и объект, на
котором вызван `#instance_eval` (_receiver_), а точнее:
* _lexical scope_'ы и иерархия классов объекта, **где** `#instance_eval`
вызван (_caller scope_) с одной стороны,
* и иерархия классов объекта, **на котором** `#instance_eval` вызван
(_receiver_), с другой.

И непонятно чего ждать от Ruby. Непонятно даже как это _должно_
работать.

Разработчики Ruby разрешили неоднозначность любопытным образом - Ruby
использует и _caller_ и _receiver_. При вызове `#instance_eval` со строкой
стандартный механизм _constant lookup_ расширяется и Ruby ищет константу
в следующих местах и следующем порядке:
* _singleton class_ _receiver_'а
* класс _receiver_'а
* _caller lexical scope_
* внешние _lexical scope_'ы для _caller scope_'а
* класс _receiver_'а (опять)
* цепочка наследования класса _receiver_'а



### Пример

Рассмотрим на примере.

```ruby
module M1
  module M2
    class A
    end

    class B < A
      def foo(obj)
        obj.instance_eval "FOO"
      end
    end
  end
end

module M3
  module M4
    class C
    end

    class D < C
    end
  end
end
```

Если вызвать метод `foo`, то:
* _receiver_ - это объект класса `D`, который наследует класс `C` и вложен в
модули `M4` и `M3` (внешние _lexical scope_'ы)
* _caller scope_ - это класс `B`, который наследует класс `A` и вложен в
модули `M2` и `M1`.

```ruby
object = M3::M4::D.new
M1::M2::B.new.foo(object)
```

При поиске константы `FOO` классы и модули будут проверяться в следующем
порядке:
* _singleton class_ _receiver_'а (`object`)
* `D` - класс _receiver_'а
* `B` - _caller scope_
* `M2` - внешний _lexical scope_ для класса `B`
* `M1` - внешний _lexical scope_ для модуля `M2`
* `D` - класс _receiver_'а
* `C` - родительский класс класса `D`

Наглядно это выглядит так:

```ruby
module M1
  # 4

  module M2
    # 3

    class A
    end


    class B < A # caller
      # 2

      def foo(obj)
        obj.instance_eval "FOO"
      end
    end
  end
end


module M3
  module M4
    class C
      # 6
    end


    class D < C # receiver
      # 1, 5
    end
  end
end
```



### Наблюдения

Замечу, что здесь игнорируются _lexical scope_'ы класса _receiver_'а
(модули `M4` и `M3`) и иерархия наследования класса _caller scope_'а
(класс `A`).

Еще один момент - механизм _constant lookup_ в `#instance_eval` в Ruby
3.0 и ранее немного отличается. В Ruby 3.1 (как описано выше) поиск начинается с
_singleton class_'а _receiver_'а, а затем идет класс _receiver_'а и
_caller lexical scope_. В Ruby 3.0 второй шаг пропускался - после
_singleton class_'а _receiver_'а проверялся сразу _caller lexical scope_. А
класс _receiver_'а проверялся уже после цепочки _lexical scopes_, как
часть иерархии наследования для _receiver_'а.



### PS

Ситуация с `#instance_eval` ожидаемая - получилось как получилось.
Логика странная и сложная. Нигде не описана и меняется в минорных
версиях Ruby. Трудно представить (и негде прочитать) мотивы
разработчиков.

Возникают также вопросы:
- а зачем ставить _singleton class_ и класс _receiver_'а на первое место?
- и почему игнорируется иерархия классов _caller_'а? Почему бы и там еще
не поискать?



### Ссылки

- <http://valve.github.io/blog/2013/10/26/constant-resolution-in-ruby/>
- <https://cirw.in/blog/constant-lookup.html>
- <https://www.bigbinary.com/blog/understanding-instance-exec-in-ruby>
- <https://github.com/oracle/truffleruby/commit/f9113553823106072f9979b72ccaae9a7e372119>

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
