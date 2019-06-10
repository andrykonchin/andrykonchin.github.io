---
layout:     post
title:      "Небезопасный SecureRandom"
date:       2019-06-10 21:11
categories: Ruby
---

Уже не вспомнить как, но однажды я наткнулся на [тикет](https://bugs.ruby-lang.org/issues/9569) в багтрекере Ruby с обсуждением класса [`SecureRandom`](https://ruby-doc.org/stdlib-2.6.1/libdoc/securerandom/rdoc/SecureRandom.html) из стандартной библиотеки. Я так увлекся, что провел весь вечер за чтением этого длиннющего треда. Он полон эмоций, страстей, презрения, упреков и негодования. Рекомендую как-нибудь тоже полистать на досуге. В то же время в нем затронули вопрос алгоритмов криптографии и их поддержки в операционных системах. И я не смог удержаться и не описать кратко ход событий.

Но вначале небольшое отступление, чтобы была понятна суть проблемы.

#### SecureRandom

`SecureRandom` позволяет генерировать последовательность случайных байт заданной длины и гарантирует высокий уровень этой случайности. Он предназначен в первую очередь для реализации механизмов безопасности приложения. Например, в Rails он используется для генерации _secret key_ приложения, _session id_, _csrf_ токенов, _UUID_'ов итд.

Приведу примеры из документации:

```ruby
SecureRandom.random_bytes(10) #=> "\016\t{\370g\310pbr\301"
SecureRandom.random_bytes(10) #=> "\323U\030TO\234\357\020\a\337"

SecureRandom.uuid #=> "2d931510-d99f-494a-8c67-87feb05e1594"
SecureRandom.uuid #=> "bad85eb9-0713-4da7-8d36-07a8e4b00eab"
```

Фактически `SecureRandom` это [CSPRNG](https://en.wikipedia.org/wiki/Cryptographically_secure_pseudorandom_number_generator) (cryptographically secure pseudo-random number generator) и является оберткой над уже существующими реализациями.

С седых времен для выбора PRNG в `SecureRandom` применялась следующая логика:

1. PRNG из OpenSSL, если она доступна в системе
2. `/dev/urandom` - псевдофайл в Unix системах, использует CSPRNG,
   реализованный в ядре операционной системы
3. `CryptGenRandom` - системный вызов WinAPI в Windows
4. `raise NotImplementedError, "No random device"` в противном случае

Именно в этом порядке приоритетов и заключается проблема, описанная в
тикете.

#### CSPRNG и немного теории

Генераторы по настоящему случайных данных [HRNG](https://en.wikipedia.org/wiki/Hardware_random_number_generator) (hardware random number generator) существуют и используются но обладают относительно низкой скоростью генерации. Поэтому генераторы псевдослучайных чисел [PRNG](https://en.wikipedia.org/wiki/Pseudorandom_number_generator) (pseudorandom number generator) применяются намного шире. PRNG это алгоритм генерации числового ряда, который обычно инициализируется (сидируется) по настоящему случайными данными из HRNG.

CSPRNG - это PRNG которые обладают свойствами, которые делают их применимыми в криптографии:
* они проходят тесты на статистическую случайность ([Next-bit test](https://en.wikipedia.org/wiki/Next-bit_test)) - т.е. нельзя предугадать следующий генерируемый бит с вероятностью выше 50% за полиномиальное время
* они устойчивы к атакам даже если известно частично начальное
состояние.

Основное свойство CSPRNG - очень трудно (но не невозможно) заранее предугадать генерируемые данные.

CSPRNG делят на следующие типы:
* основанные на шифрах или [криптографических хеш-функциях](https://en.wikipedia.org/wiki/Cryptographic_hash_function)
* основанные на трудно вычислимых математических задачах
* все остальные алгоритмы, не вошедшие в предыдущие категории, например:
  * [Yarrow](https://en.wikipedia.org/wiki/Yarrow_algorithm) - используется в MacOS, в том числе для `/dev/random`
  * [ChaCha20](https://en.wikipedia.org/wiki/Salsa20#ChaCha_variant), который используется в OpenBSD, FreeBSD, NetBSD и Linux
  * [arc4random](https://en.wikipedia.org/wiki/RC4#RC4-based_random_number_generators)

CSPRNG стали неотъемлемой частью ядер современных операционных систем. В Unix'ах они доступены как через системные вызовы, специфичные для каждой системы, так и через более-менее универсальный интерфейс - псевдофайлы `/dev/random` и `/dev/urandom`.

CSPRNG работают по одному и тому же принципу. При старте операционной системы генерируется по настоящему случайные данные (_entropy pool_) используя HRNG и затем они используется для инициализации CSPRNG (обычно это ChaCha20). Если приложение обращается к PRNG до завершения генерации _entropy pool_, то возможны два варианта:
* вызов блокируется пока _entropy pool_ не "наполнится" или
* PRNG будет проинициализирован псевдослучайными данными, что конечно же уменьшает случайность.

#### Итак, шел 2014 год

Некий Corey Csuhta создал [тикет](https://bugs.ruby-lang.org/issues/9569) и предложил Ruby core team отказаться от использования OpenSSL в `SecureRandom`, ибо оно дырявое как решето, а реализация в ядре операционной системы намного надежнее и проще. В ней может разобраться даже ~~ребенок~~… обычный опытный разработчик на Си, а не то что Ruby core team. Приводили примеры [реализации](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/char/random.c) в Linux, [реализации](https://github.com/jedisct1/libsodium/blob/master/src/libsodium/randombytes/sysrandom/randombytes_sysrandom.c) в libsodium, [реализации](https://github.com/jedisct1/libsodium/blob/master/src/libsodium/randombytes/sysrandom/randombytes_sysrandom.c#L36) функции arc4random в OpenBSD и даже [реализацию](https://github.com/php/php-src/blob/master/ext/standard/random.c), прости, Господи, в PHP.

PRNG в OpenSSL печально известен серией багов и уязвимостей ([тыц](https://wiki.openssl.org/index.php/Random_fork-safety), [тыц](https://research.swtch.com/openssl), [тыц](https://arstechnica.com/information-technology/2013/08/google-confirms-critical-android-crypto-flaw-used-in-5700-bitcoin-heist/) и наконец [тыц](https://github.com/ramsey/uuid/issues/80)). С одним из них (random fork-safety) даже связан [костыль](https://github.com/ruby/ruby/commit/58bae71a7b023b5bb5fdcfefb46232f3f14bc519#diff-66b307ffeac2ecae9561c62325c5a072) в `SecureRandom`. Один из участников обсуждения создал [_issue_](https://github.com/openssl/openssl/issues/898) в проекте OpenSSL по этому поводу.

Позиция core team была следующей - OpenSSL наше все, хоть и дырявое, а на `/dev/urandom` перейти нельзя, потому что в (устаревшей) _man_ странице Linux не рекомендовали использовать `/dev/urandom` как CSPRNG. В документации MacOS, FreeBSD и OpenBSD, кстати, такого предупреждения не было. Таким образом, из-за устаревшей документации Linux Ruby не использует PRNG операционной системы как на Unix'ах так и на Windows.

Оказалось, что по поводу этой устаревшей _man_ страницы в Linux был заведен даже [баг](https://bugzilla.kernel.org/show_bug.cgi?id=71211) но заниматься им никто не спешил.

#### Тем временем шел 2015 год

Как будто в ответ на критику в треде Ruby core team решила принять меры и [усилила безопасность](https://github.com/ruby/ruby/commit/7104a473ea77fa34ffbf831b64b94d0e58cb68f0)  `SecureRandom`, начав инициализировать PRNG OpenSSL случайными байтами, сгенерированными PRNG операционной системы. На это сообщество отреагировало негативно и в самом коммите на Github и в [треде](https://bugs.ruby-lang.org/issues/9569#note-13).

Примечательно, но один из Ruby committers (NARUSE, Yui, aka nurse) сделал [обертку](https://github.com/nurse/securerandom) над библиотечными функциями BSD/Linux [arc4random_buf](http://manpages.ubuntu.com/manpages/xenial/man3/arc4random.3.html), которая повторяла интерфейс стандартного `SecureRandom` но не использовала OpenSSL, и выложил это в виде _gem_'а. Еще можно было использовать _binding_ к [libsodium](https://libsodium.gitbook.io/doc/) ([rbnacl](https://github.com/crypto-rb/rbnacl)), кросплатформенной библиотеке криптографических алгоритмов, или [еще одну обертку](https://github.com/cryptosphere/sysrandom) над libsodium, которая реализовывала интерфейс `SecureRandom`.

Немного изменилась и позиция Ruby core team. Они согласились, что реализация PRNG в Linux читабельна, и признали, что `/dev/urandom` надежен. Но не хватает только официального подтверждения, что в Linux приложения могут интенсивно использовать `/dev/urandom`. Вернее, документация утверждает обратное.

Прозвучала даже мысль вынести `SecureRandom` в отдельный _gem_, чтобы его обновление было независимо от релизов самого Ruby. И если будет найдена уязвимость, то надо будет просто зарелизить новую версию _gem_'а.

Привели также результат [Diehard теста](https://en.wikipedia.org/wiki/Diehard_tests) (набора статистических тестов для измерения качества набора случайных чисел) для `SecureRandom` и `/dev/urandom` в Debian. Результат ожидаем - 6 непройденных тестов у `SecureRandom` и 1 у `/dev/urandom` ([отчет](http://nopaste.narf.at/show/i0EJbkQrL3SXurfQZ524/)).

#### Наступил 2017 год

Наконец-то в Linux обновилась документация ([random (4)](http://man7.org/linux/man-pages/man4/random.4.html), [random (7)](http://man7.org/linux/man-pages/man7/random.7.html)). В треде об этом просигналили и через несколько месяцев в `SecureRandom` логика выбора PRNG [была изменена](https://github.com/ruby/ruby/commit/abae70d6ed63054d7d01bd6cd80c1b5b98b93ba3). Вначале `SecureRandom` обращается к PRNG операционной системы и далее уже к OpenSSL, как и предлагалось изначально в тикете.

Новые приоритеты выбора PRNG в SecureRandom :
1. CSPRNG реализация операционной системы, один из:
    * системный вызов `getrandom(2)`,
    * `arc4random(3)` или
    * системный вызов `CryptGenRandom`
2. `/dev/urandom файл`
3. OpenSSL - `RAND_bytes(3)`

Системный вызов [`getrandom`](http://man7.org/linux/man-pages/man2/getrandom.2.html) в Linux/BSD  практически эквивалентен чтению из `/dev/urandom` псевдофайла, но имеет ряд дополнительных возможностей. Кроме того, системный вызов более безопасный, так как будет блокировать вызов если _entropy pool_ операционной системы еще не "заполнен".

Библиотечная функция [`arc4random`](https://man.openbsd.org/arc4random.3) (на самом деле целый набор функций) это еще один PRNG, доступный в Unix'ах. Изначально он возник в BSD системах, был портирован на Linux и теперь доступен там в составе библиотеки [libbsd](https://libbsd.freedesktop.org/wiki/). В начале там использовался ARC4 шифр, который затем постепенно был заменен на ChaCha20.

Это изменение вошло в [Ruby 2.5](https://github.com/ruby/ruby/blob/v2_5_0/NEWS) и стало доступным в декабре 2017 спустя 4 года с создания тикета и начала обсуждения. В списке изменений появился следующий лаконичный пункт:

> "SecureRandom now prefers OS-provided sources than OpenSSL. [Bug #9569]”

#### Эпилог

Несмотря на консервативность и упертось Ruby core team теперь в Ruby есть надежный CSPRNG из коробки, который доступен через `SecureRandom.random_bytes`. Осталось только дождаться гемификации и выноса этой библиотеки в независимый gem.

Одновременно с обсуждением шла работа над улучшением CSPRNG в ядре Linux. В 2016 они перешли на новый алгоритм (ChaCha20), который к тому времени уже использовался во всех BSD системах, и было сделано много других изменений, в которые я не углублялся (детали [здесь](https://bugs.ruby-lang.org/issues/9569#note-54), [пример](https://marc.info/?l=linux-crypto-vger&m=146217043829396&w=2) и [еще один](https://marc.info/?l=linux-crypto-vger&m=146588259306658&w=2)).

Параллельно с этим в OpenSSL закрыли _issue_ и [отрапортовали](https://github.com/openssl/openssl/issues/898#issuecomment-322794837), что их PRNG переписан с нуля и теперь белый и пушистый. Это изменение стало доступным в 2018 году в версии 1.1.1 ([CHANGES](https://github.com/openssl/openssl/blob/master/CHANGES)):

> Grand redesign of the OpenSSL random generator
>
> The default RAND method now utilizes an AES-CTR DRBG according to
> NIST standard SP 800-90Ar1. The new random generator is essentially
> a port of the default random generator from the OpenSSL FIPS 2.0
> object module. It is a hybrid deterministic random bit generator
> using an AES-CTR bit stream and which seeds and reseeds itself
> automatically using trusted system entropy sources.

#### Ссылки

* [Cryptographically secure pseudorandom number generator](https://en.wikipedia.org/wiki/Cryptographically_secure_pseudorandom_number_generator)
* [On entropy and randomness](https://lwn.net/Articles/261804/)
* [The plain simple reality of entropy](https://media.ccc.de/v/32c3-7441-the_plain_simple_reality_of_entropy) ([слайды](https://speakerdeck.com/filosottile/the-plain-simple-reality-of-entropy-at-32c3))
* [Falko Strenzke. An Analysis of OpenSSL’s Random Number Generator](https://eprint.iacr.org/2016/367.pdf)
* [Patrick Lacharme, Andrea Röck, Vincent Strubel, Marion Videau. The Linux Pseudorandom Number Generator Revisited](https://eprint.iacr.org/2012/251.pdf)

[jekyll-gh]: https://github.com/mojombo/jekyll
[jekyll]:    http://jekyllrb.com
