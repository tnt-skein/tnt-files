--- Диск: один договор над драйвером — положить, взять, потоком, есть ли,
--- удалить, копия, перенос, размер, публичный адрес, ссылка со сроком.
---
---     local disk = store:disk('uploads')
---
---     disk:put('avatars/7.png', png, { type = 'image/png' })   --> true
---     disk:get('avatars/7.png')                                --> строка
---     disk:put('exports/big.csv', fs.reader('/tmp/big.csv'))   --> true, кусками
---     local reader = disk:stream('exports/big.csv')            --> кусками
---     disk:url('avatars/7.png')                                --> публичный адрес
---     disk:temporary_url('avatars/7.png', 600)                 --> ссылка на 10 минут
---
--- Что прикладной код видит одинаковым на любом драйвере:
---
--- * **Путь** — отрезки через «/», без ведущей «/», без пустых, `.`, `..`
---   и управляющих знаков. Негодный путь — исключение: путь из присланного
---   имени обязан пройти через безопасное имя (`file.name` у `tnt-router`),
---   а шаг вверх, дошедший до диска, — ошибка кода, а не отказ хранилища.
--- * **Отказ — пара `nil, err` с родом `tnt.files.failure`**: `missing`,
---   `denied`, `full`, `unavailable`, `failed`. «Файла нет» — отказ
---   `missing` у всех действий, которым файл нужен.
--- * **Удаление того, чего нет, — удача**: ведро на удаление отвечает одинаково,
---   был объект или нет, и локальный диск отвечает так же.
--- * **Каталогов нет.** Путь с «/» кладёт файл, промежуточные каталоги
---   локальный диск заводит сам; каталог по пути — не файл: его нет.
--- * **Запись атомарна**: читающий видит либо прежний файл, либо новый.

local must = require('tnt.must')
local fs = require('tnt.fs')

local failure = require('tnt.files.failure')
local reader_of = require('tnt.files.reader')
local writer_of = require('tnt.files.writer')

local Module = {}

--- Самый длинный путь: 1024 байта — столько берёт ключ S3.
Module.MAX_PATH = 1024

--- Самый долгий срок ссылки: семь суток — дольше ведро не подписывает,
--- а договор у дисков один.
Module.MAX_EXPIRES = 7 * 24 * 60 * 60

--- Настройки записи.
local PUT = { type = '?not_empty' }

---@class TntFilesPutOptions
---@field type string|nil Вид содержимого (`image/png`): его хранит ведро; у локального диска вида нет

---@class TntFilesBackend Драйвер под диском: отвечает своими отказами, `kind` переводит их в род диска
---@field name string Имя драйвера
---@field temporary boolean Умеет ли ссылку со сроком
---@field kind fun(err: any): string Род диска по отказу драйвера
---@field get fun(self: any, path: string): (string|nil, any)
---@field reader fun(self: any, path: string): (any, any)
---@field writer fun(self: any, path: string, opts: table): (any, any)
---@field put fun(self: any, path: string, content: string, opts: table): (true|nil, any)
---@field exists fun(self: any, path: string): (boolean|nil, any)
---@field delete fun(self: any, path: string): (true|nil, any)
---@field copy fun(self: any, from: string, to: string): (true|nil, any)
---@field move fun(self: any, from: string, to: string): (true|nil, any)
---@field size fun(self: any, path: string): (number|nil, any)
---@field temporary_url fun(self: any, path: string, expires: integer): (string|nil, any)

---@class TntFilesDisk Диск
---@field name string Имя диска
---@field driver string Драйвер: local либо s3
---@field backend TntFilesBackend
---@field base string|nil Публичный адрес без «/» на конце
local Disk = {}
Disk.__index = Disk

--- Заводит диск над драйвером.
---@param name string
---@param settings TntFilesDiskSettings
---@param backend TntFilesBackend
---@return TntFilesDisk
function Module.new(name, settings, backend)
    return setmetatable({ name = name, driver = backend.name, backend = backend, base = settings.url }, Disk)
end

--- Проверяет путь на диске.
---@param path any
---@param name string Как назвать путь в отказе
---@param level integer Уровень вины в кадрах того, кто зовёт
local function check_path(path, name, level)
    must.at(level + 1).not_empty(path, name)

    if #path > Module.MAX_PATH then
        error(('%s длиннее %d байт: %d'):format(name, Module.MAX_PATH, #path), level + 1)
    end

    if path:find('%c') ~= nil or ('/' .. path .. '/'):find('/%.?%.?/') ~= nil then
        error(
            ('%s — отрезки через «/» без пустых, «.», «..» и управляющих знаков, а не «%s»'):format(
                name,
                path
            ),
            level + 1
        )
    end
end

--- Итог драйвера: значение — как есть, пусто — отказ диска.
---@param disk TntFilesDisk
---@param path string
---@param doing string
---@param value any
---@param err any
---@return any value
---@return TntFilesFailure|nil err
local function outcome(disk, path, doing, value, err)
    if value == nil then
        return nil, failure.of(disk.backend.kind, disk.name, path, doing, err)
    end

    return value
end

--- Открывает запись файла кусками: файл встаёт на место в `finish`.
---@param path string
---@param opts TntFilesPutOptions|nil
---@return TntFilesWriter|nil writer
---@return TntFilesFailure|nil err
function Disk:writer(path, opts)
    check_path(path, 'путь', 2)
    must.at(2).optional.options(opts, 'настройки записи', PUT)

    local doing = ('файл %s не записан'):format(path)
    local inner, err = self.backend:writer(path, opts or {})

    if inner == nil then
        return nil, failure.of(self.backend.kind, self.name, path, doing, err)
    end

    return writer_of.new(inner, self.backend.kind, self.name, path, doing)
end

--- Кладёт файл: строку целиком либо читателя кусками.
---
--- Читатель — всякий с договором `tnt-fs` (`read()`, `close()`):
--- `fs.reader` файла, `stream` другого диска, `reader` ведра. Он читается
--- до конца и закрывается; отказ его чтения приходит как есть — это отказ
--- источника, а не диска.
---@param path string
---@param content string|table Строка либо читатель
---@param opts TntFilesPutOptions|nil
---@return true|nil ok
---@return TntFilesFailure|any err
function Disk:put(path, content, opts)
    check_path(path, 'путь', 2)
    must.at(2).optional.options(opts, 'настройки записи', PUT)

    local doing = ('файл %s не записан'):format(path)

    if type(content) == 'string' then
        return outcome(self, path, doing, self.backend:put(path, content, opts or {}))
    end

    must.at(2).table(content, 'содержимое')

    -- Присланный файл роутера похож на читателя, но им не является: его
    -- `read()` отдаёт файл целиком на каждый вызов, и переливание не
    -- кончилось бы, пока не кончится место.
    if content.client_name ~= nil then
        error(
            'содержимое — присланный файл, а не читатель: file.path — в fs.reader, file:read() — строкой',
            2
        )
    end

    local writer, err = self:writer(path, opts)

    if writer == nil then
        content:close()

        return nil, err
    end

    return fs.pipe(content, writer)
end

--- Файл целиком строкой.
---@param path string
---@return string|nil content
---@return TntFilesFailure|nil err
function Disk:get(path)
    check_path(path, 'путь', 2)

    return outcome(self, path, ('файл %s не прочитан'):format(path), self.backend:get(path))
end

--- Открывает файл на чтение кусками.
---@param path string
---@return TntFilesReader|nil reader
---@return TntFilesFailure|nil err
function Disk:stream(path)
    check_path(path, 'путь', 2)

    local doing = ('файл %s не прочитан'):format(path)
    local inner, err = self.backend:reader(path)

    if inner == nil then
        return nil, failure.of(self.backend.kind, self.name, path, doing, err)
    end

    return reader_of.new(inner, self.backend.kind, self.name, path, doing)
end

--- Есть ли файл. Каталог по пути — не файл.
---@param path string
---@return boolean|nil found
---@return TntFilesFailure|nil err
function Disk:exists(path)
    check_path(path, 'путь', 2)

    return outcome(self, path, ('файл %s не проверен'):format(path), self.backend:exists(path))
end

--- Удаляет файл; файла не было — тоже удача.
---@param path string
---@return true|nil ok
---@return TntFilesFailure|nil err
function Disk:delete(path)
    check_path(path, 'путь', 2)

    return outcome(self, path, ('файл %s не удалён'):format(path), self.backend:delete(path))
end

--- Копия и перенос на то же место: файл уже там, и отвечать надо
--- только, есть ли он.
---
--- Руками драйвера такое действие опасно: ведро копию объекта на себя
--- отвергает, а перенос у ведра — копия и удаление, и служба, принявшая
--- копию на себя, лишилась бы объекта на удалении.
---@param backend TntFilesBackend
---@param path string
---@return true|nil ok Нет файла — пусто без отказа
---@return any err
local function in_place(backend, path)
    local found, err = backend:exists(path)

    return found or nil, err
end

--- Копирует файл; место копии занято — копия ложится поверх.
---@param from string
---@param to string
---@return true|nil ok
---@return TntFilesFailure|nil err
function Disk:copy(from, to)
    check_path(from, 'откуда', 2)
    check_path(to, 'куда', 2)

    local doing = ('файл %s не скопирован в %s'):format(from, to)

    if from == to then
        return outcome(self, from, doing, in_place(self.backend, from))
    end

    return outcome(self, from, doing, self.backend:copy(from, to))
end

--- Переносит файл; место занято — файл ложится поверх.
---@param from string
---@param to string
---@return true|nil ok
---@return TntFilesFailure|nil err
function Disk:move(from, to)
    check_path(from, 'откуда', 2)
    check_path(to, 'куда', 2)

    local doing = ('файл %s не перенесён в %s'):format(from, to)

    if from == to then
        return outcome(self, from, doing, in_place(self.backend, from))
    end

    return outcome(self, from, doing, self.backend:move(from, to))
end

--- Размер файла в байтах.
---@param path string
---@return number|nil size
---@return TntFilesFailure|nil err
function Disk:size(path)
    check_path(path, 'путь', 2)

    return outcome(self, path, ('размер файла %s не узнан'):format(path), self.backend:size(path))
end

--- Знак пути в адресе: `%XX`.
---@param char string
---@return string
local function encoded(char)
    return ('%%%02X'):format(char:byte())
end

--- Публичный адрес файла: адрес диска и путь, отрезки закодированы.
---
--- В сеть не ходит и не проверяет, есть ли файл. Без настройки `url` —
--- исключение: адрес, которого нет, — промах того, кто настраивал диск,
--- и заметить его надо на первом вызове, а не в разосланном письме.
---@param path string
---@return string
function Disk:url(path)
    check_path(path, 'путь', 2)

    if self.base == nil then
        error(
            ('у диска %s нет публичного адреса — настройка url'):format(self.name),
            2
        )
    end

    -- Кодируется всё, кроме незарезервированных знаков RFC 3986 и «/»
    -- между отрезками.
    return self.base .. '/' .. path:gsub('[^%w%-%._~/]', encoded)
end

--- Ссылка на файл со сроком: по ней файл заберёт тот, у кого прав нет.
---
--- Ведро подписывает ссылку само; локальный диск — функцией `sign`
--- из настроек (обычно `signed_url` роутера, который файл и раздаёт).
--- Диск без подписи — исключение, как и без `url`.
---@param path string
---@param expires integer Сколько секунд ссылка годна, от 1 до 604800
---@return string|nil url
---@return TntFilesFailure|nil err
function Disk:temporary_url(path, expires)
    check_path(path, 'путь', 2)
    must.at(2).between(expires, 'срок ссылки', 1, Module.MAX_EXPIRES)
    must.at(2).integer(expires, 'срок ссылки')

    if not self.backend.temporary then
        error(
            ('у диска %s нет подписи ссылок со сроком — настройка sign'):format(
                self.name
            ),
            2
        )
    end

    return outcome(
        self,
        path,
        ('ссылка на файл %s не подписана'):format(path),
        self.backend:temporary_url(path, expires)
    )
end

return Module
