# tnt-files

Диски приложения для Tarantool: у диска имя, драйвер и один договор
на всех драйверах — положить, взять, потоком, есть ли, удалить, копия,
перенос, размер, публичный адрес и ссылка со сроком. Драйвер `local`
держит файлы в каталоге узла, драйвер `s3` — объекты в ведре.

```lua
local files = require('tnt.files')

local store = files.new({
    default = 'local',
    disks = {
        ['local'] = { driver = 'local', root = '/var/lib/app/storage', url = '/storage' },
        uploads = { driver = 's3', client = bucket, prefix = 'uploads/', url = 'https://cdn.example.org/uploads' },
    },
})

store:disk('uploads'):put('avatars/7.png', png, { type = 'image/png' })   --> true
store:disk():get('avatars/8.png')          --> nil, диск local: файл avatars/8.png не прочитан: файла нет
```

Зависимости: [`tnt-must`](https://github.com/tnt-skein/tnt-must)
и [`tnt-fs`](https://github.com/tnt-skein/tnt-fs). Клиент ведра —
[`tnt-s3`](https://github.com/tnt-skein/tnt-s3) — приходит настройкой
диска `client`, и пакет от него не зависит.

## Зачем

Файлы узла и объекты в ведре — два разных предмета с разными отказами:
у файла — род и `errno`, у ведра — код ответа, а «нет объекта» у `get` —
вовсе `nil` без отказа. Код, который кладёт загрузку посетителя, при
таком раскладе знает, куда она ляжет. Здесь место выбирает настройка,
а код одинаков:

- **Один договор.** «Файла нет» — отказ `missing` у всех действий,
  которым файл нужен; удаление того, чего нет, — удача; каталоги под
  файлом локальный диск заводит сам; каталог по пути — не файл.
- **Один род отказа.** `missing`, `denied`, `full`, `unavailable`,
  `failed` — на любом драйвере; отказ драйвера как есть лежит
  в `err.cause`.
- **Поток на обоих драйверах.** Файл в сотни мегабайт читается и пишется
  кусками: в памяти узла лежит один кусок, сколько бы ни весил файл.
- **Адрес файла.** Публичный — из настройки диска, ссылка со сроком —
  подписью ведра либо функцией `sign` того, кто раздаёт файлы каталога.

## Установка

```sh
tt rocks install tnt-files --server=https://tnt-skein.github.io/rocks
```

Или из исходников:

```sh
git clone https://github.com/tnt-skein/tnt-files.git
cd tnt-files && tt rocks make
```

## Как пользоваться

| Вызов | Что отдаёт |
|---|---|
| `files.new({ default, disks })` | диски по именам; в сеть и на диск не ходит |
| `store:disk(name)` | диск по имени; без имени — диск по умолчанию |
| `disk:put(path, content, { type })` | `true`; `content` — строка либо читатель кусками |
| `disk:get(path)`, `disk:stream(path)` | содержимое строкой; читатель кусками |
| `disk:writer(path, { type })` | писатель кусками: файл встаёт на место в `finish` |
| `disk:exists(path)`, `disk:size(path)` | есть ли файл; размер в байтах |
| `disk:delete(path)` | `true`; файла не было — тоже `true` |
| `disk:copy(from, to)`, `disk:move(from, to)` | `true`; место занято — файл ложится поверх |
| `disk:url(path)` | публичный адрес диска и путь, отрезки закодированы |
| `disk:temporary_url(path, expires)` | ссылка на `expires` секунд, от 1 до 604800 |

Отказ — пара `nil, err`; `err` читается и как строка:

```lua
local _, err = store:disk():get('avatars/8.png')

err.kind                 --> 'missing'
tostring(err)            --> диск local: файл avatars/8.png не прочитан: файла нет
files.is_failure(err)    --> true
```

Поток — читатель и писатель по договору `tnt-fs`, их понимают файл,
ведро и диск:

```lua
local disk = store:disk('uploads')

disk:put('exports/big.csv', fs.reader('/tmp/big.csv'))                --> true, кусками
store:disk('local'):put('copy.csv', disk:stream('exports/big.csv'))   --> true: из ведра в каталог
```

Негодная настройка, незнакомый диск и негодный путь (`..`, пустой
отрезок, управляющий знак) — исключение на строке того, кто позвал.

## Проверки

```sh
make deps          # luatest, luacheck, luacov с cluacov, рок http, зависимости пакета и соседи проверок в .rocks
make check         # форматирование, линт, проверки, покрытие с порогом 100 %
make mutants-all   # мутационное тестирование утилитой tnt-mutants из PATH, порог 100 % убитых
make s3-up         # Garage в докере для живых проверок; make s3-down гасит
```

Покрытие строк — 100 %, убитых мутантов — 100 % (59 проверок, из них
4 живых на Garage; 367 мутантов в восьми модулях). Локальный диск
проверяется на настоящем каталоге, ведро — настоящим клиентом `tnt-s3`
на двойнике libcurl; живые проверки гонят 50 МБ потоком в обе стороны
и открывают ссылки со сроком, у каталога — через настоящий роутер
`tnt-router`. Без Garage живые проверки пропускаются.

## Документ

Полное описание с настройками дисков, договором, отказами, потоком,
адресами и обоснованием решений: [docs/files.md](docs/files.md).

## Лицензия

MIT.
