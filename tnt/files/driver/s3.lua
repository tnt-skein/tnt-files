--- Драйвер `s3`: объекты ведра через клиент `tnt-s3`, пришедший настройкой
--- `client`.
---
--- Клиент — аргумент, а не зависимость пакета: его заводит приложение
--- своими настройками (ключи, узел, срок, повторы), и одно ведро служит
--- многим дискам — у каждого своя приставка ключей `prefix`. Путь диска —
--- ключ объекта после приставки.
---
--- Что драйвер берёт у клиента: `get`, `head`, `put`, `delete`, `copy`,
--- `presign`, `reader` и `writer`. Копия и перенос идут силами службы —
--- байты через узел не ходят; перенос — копия и удаление: переименования
--- у S3 нет. Чтение и запись кусками — запросами с диапазоном и загрузкой
--- частями: в памяти узла лежит одна часть, сколько бы ни весил файл.

local failure = require('tnt.files.failure')

local Module = {}

--- Код S3, с которым «нет источника» у копии — «файла нет», а не отказ.
local NO_SUCH_KEY = 'NoSuchKey'

--- Род диска по роду отказа `tnt-storage`; прочее — `failed`.
---
--- Всё, что лечит время, — сеть, срок, занятость, обрыв, закрытый
--- драйвер, — это «сейчас не отвечает».
local KINDS = {
    denied = failure.DENIED,
    unreachable = failure.UNAVAILABLE,
    busy = failure.UNAVAILABLE,
    timeout = failure.UNAVAILABLE,
    broken = failure.UNAVAILABLE,
    closed = failure.UNAVAILABLE,
}

---@class TntFilesS3 Драйвер s3
---@field name string
---@field temporary boolean Подписывает ли ссылки со сроком: ведро — всегда
---@field client TntS3Client
---@field prefix string
local S3 = {}
S3.__index = S3

--- Род диска по отказу драйвера.
---@param err any
---@return string
function S3.kind(err)
    if err.server_code == NO_SUCH_KEY then
        return failure.MISSING
    end

    return KINDS[err.kind] or failure.FAILED
end

--- Заводит драйвер. В сеть не ходит.
---@param settings TntFilesDiskSettings
---@return TntFilesS3
function Module.new(settings)
    return setmetatable({ name = 's3', temporary = true, client = settings.client, prefix = settings.prefix }, S3)
end

--- Ключ объекта по пути диска.
---@param driver TntFilesS3
---@param path string
---@return string
local function key_of(driver, path)
    return driver.prefix .. path
end

--- Удача — `true`, отказ — как есть: клиент отвечает сведениями о записанном,
--- а диску они не нужны.
---@param stored any
---@param err any
---@return true|nil ok
---@return any err
local function done(stored, err)
    if stored == nil then
        return nil, err
    end

    return true
end

---@param path string
---@return string|nil content Промах — nil без отказа
---@return any err
function S3:get(path)
    local body, err = self.client:get(key_of(self, path))

    if body == nil then
        return nil, err
    end

    return body
end

---@param path string
---@return TntS3Download|nil reader Промах — nil без отказа
---@return any err
function S3:reader(path)
    local reader, err = self.client:reader(key_of(self, path))

    return reader, err
end

---@param path string
---@param opts TntFilesPutOptions
---@return TntS3Upload writer
function S3:writer(path, opts)
    local writer = self.client:writer(key_of(self, path), { content_type = opts.type })

    return writer
end

---@param path string
---@param content string
---@param opts TntFilesPutOptions
---@return true|nil ok
---@return any err
function S3:put(path, content, opts)
    return done(self.client:put(key_of(self, path), content, { content_type = opts.type }))
end

---@param path string
---@return boolean|nil found
---@return any err
function S3:exists(path)
    local info, err = self.client:head(key_of(self, path))

    if err ~= nil then
        return nil, err
    end

    return info ~= nil
end

---@param path string
---@return true|nil ok
---@return any err
function S3:delete(path)
    return self.client:delete(key_of(self, path))
end

---@param from string
---@param to string
---@return true|nil ok
---@return any err
function S3:copy(from, to)
    return done(self.client:copy(key_of(self, from), key_of(self, to)))
end

--- Перенос — копия и удаление: переименования у S3 нет. Отказ удаления
--- после копии оставляет файл на обоих местах, и это отказ, а не удача.
---@param from string
---@param to string
---@return true|nil ok
---@return any err
function S3:move(from, to)
    local copied, err = self:copy(from, to)

    if not copied then
        return nil, err
    end

    return self:delete(from)
end

---@param path string
---@return integer|nil size Промах — nil без отказа
---@return any err
function S3:size(path)
    local info, err = self.client:head(key_of(self, path))

    if info == nil then
        return nil, err
    end

    return info.size
end

---@param path string
---@param expires integer
---@return string|nil url
---@return any err
function S3:temporary_url(path, expires)
    return self.client:presign(key_of(self, path), { expires = expires })
end

return Module
