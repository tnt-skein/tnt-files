--- Чтение файла диска кусками: куски драйвера как есть, отказы — родом
--- диска.
---
--- Договор тот же, что у читателя `tnt-fs`, поэтому читателя диска берут
--- и `fs.pipe`, и `put` другого диска: кусок — непустая строка; `nil` без
--- отказа — файл кончился; `nil, err` — отказ, и чтение кончилось.

local failure = require('tnt.files.failure')

local Module = {}

---@class TntFilesReader Чтение файла диска кусками
---@field path string Путь на диске
---@field inner any Читатель драйвера
---@field kind_of fun(err: any): string
---@field disk string
---@field doing string
---@field closed boolean
local Reader = {}
Reader.__index = Reader

--- Оборачивает читателя драйвера.
---@param inner any Читатель драйвера
---@param kind_of fun(err: any): string Род диска по отказу драйвера
---@param disk string Имя диска
---@param path string
---@param doing string Что не удалось бы, словами
---@return TntFilesReader
function Module.new(inner, kind_of, disk, path, doing)
    return setmetatable(
        { path = path, inner = inner, kind_of = kind_of, disk = disk, doing = doing, closed = false },
        Reader
    )
end

--- Следующий кусок.
---@return string|nil chunk
---@return TntFilesFailure|nil err
function Reader:read()
    -- Своя проверка, а не бросок драйвера: тот винил бы эту строку,
    -- а ошибка — у того, кто читает закрытое.
    if self.closed then
        error(
            ('read: чтение файла %s на диске %s уже закрыто'):format(self.path, self.disk),
            2
        )
    end

    local chunk, err = self.inner:read()

    if chunk == nil and err ~= nil then
        return nil, failure.of(self.kind_of, self.disk, self.path, self.doing, err)
    end

    return chunk
end

--- Закрывает читателя: дальше читать нельзя.
---@return true
function Reader:close()
    self.closed = true
    self.inner:close()

    return true
end

return Module
