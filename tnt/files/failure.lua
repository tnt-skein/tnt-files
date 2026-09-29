--- Отказ диска: один род на одну беду, какой бы драйвер ни стоял под диском.
---
--- У файлов узла и у объектов в ведре отказы разные: `tnt-fs` говорит
--- `missing` и `errno`, `tnt-s3` — `rejected` с кодом `NoSuchKey`, а «нет
--- объекта» у `get` — и вовсе `nil` без отказа. Прикладной код, который
--- решает по роду, переезжал бы с диска на ведро с правкой каждого места.
--- Поэтому род здесь свой, и родов пять:
---
--- * `missing` — файла нет;
--- * `denied` — нет прав: на каталог, на ведро, ключ доступа не тот;
--- * `full` — кончилось место или квота;
--- * `unavailable` — хранилище сейчас не отвечает: сеть, срок, служба
---   занята, драйвер закрыт; время это лечит;
--- * `failed` — всё прочее: ввод-вывод, отказ службы, объект подменён
---   посреди чтения.
---
--- Отказ драйвера как есть лежит в `cause` — тому, кому рода мало.
--- Строкой отказ читается целиком: `tostring(err)`, `'причина: ' .. err`
--- и `json.encode` дают текст «диск: что не удалось: почему».

local errno = require('errno')

local Module = {}

--- Файла нет.
Module.MISSING = 'missing'

--- Нет прав.
Module.DENIED = 'denied'

--- Кончилось место.
Module.FULL = 'full'

--- Хранилище сейчас не отвечает.
Module.UNAVAILABLE = 'unavailable'

--- Прочее.
Module.FAILED = 'failed'

---@class TntFilesFailure Отказ диска
---@field kind string Род: missing, denied, full, unavailable либо failed
---@field message string Диск, что не удалось и почему — его и отдаёт `tostring`
---@field disk string Имя диска
---@field path string Путь на диске, о котором шла речь
---@field cause any Отказ драйвера как есть; у «файла нет» без отказа — nil

--- Почему не удалось — словами драйвера.
---
--- У отказа файла с кодом — слова системы по коду: путь на узле уже назван
--- в тексте `tnt-fs`, а диску он чужой — у диска свой путь. У прочих —
--- их текст как есть.
---@param err any Отказ драйвера
---@return string
local function reason_of(err)
    if type(err) ~= 'table' then
        return tostring(err)
    end

    if err.errno ~= nil then
        return errno.strerror(err.errno)
    end

    return tostring(err.message)
end

--- Текст отказа: его отдают `tostring` и `json.encode`.
---@param failure TntFilesFailure
---@return string
local function text_of(failure)
    return failure.message
end

--- Поведение всех отказов: строкой, в JSON и в склейке они — свой текст.
local Failure = { __tostring = text_of, __serialize = text_of }

--- Склейка со строкой с любой стороны: `'причина: ' .. err`.
---@param left any
---@param right any
---@return string
function Failure.__concat(left, right)
    return tostring(left) .. tostring(right)
end

--- Отказ диска.
---@param kind string Род
---@param disk string Имя диска
---@param path string Путь на диске
---@param doing string Что не удалось, словами: «файл a.txt не прочитан»
---@param reason string Почему
---@param cause any Отказ драйвера как есть
---@return TntFilesFailure
function Module.new(kind, disk, path, doing, reason, cause)
    return setmetatable({
        kind = kind,
        message = ('диск %s: %s: %s'):format(disk, doing, reason),
        disk = disk,
        path = path,
        cause = cause,
    }, Failure)
end

--- Отказ диска по тому, что ответил драйвер.
---
--- Пусто вместо отказа — «файла нет»: так промах отдают `get` и `head`
--- ведра, и так же — локальный драйвер, когда по пути не файл.
---@param kind_of fun(err: any): string Род диска по отказу драйвера
---@param disk string Имя диска
---@param path string
---@param doing string
---@param err any Отказ драйвера либо nil
---@return TntFilesFailure
function Module.of(kind_of, disk, path, doing, err)
    if err == nil then
        return Module.new(Module.MISSING, disk, path, doing, 'файла нет', nil)
    end

    return Module.new(kind_of(err), disk, path, doing, reason_of(err), err)
end

--- Отказ ли это диска.
---@param value any
---@return boolean
function Module.is(value)
    return getmetatable(value) == Failure
end

return Module
