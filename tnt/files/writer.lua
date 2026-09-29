--- Запись файла диска кусками: куски — драйверу, отказы — родом диска.
---
--- Договор тот же, что у писателя `tnt-fs`, поэтому писателя диска берёт
--- `fs.pipe`: `write(кусок)`, `finish()` — файл встаёт на место целиком,
--- `abort()` — запись брошена, и файла нет. Отказ записи кончает её:
--- драйвер уже убрал черновик — временный файл либо начатую загрузку,
--- и дальше писатель отвечает тем же отказом.

local failure = require('tnt.files.failure')
local must = require('tnt.must')

local Module = {}

---@class TntFilesWriter Запись файла диска кусками
---@field path string Путь на диске
---@field inner any Писатель драйвера
---@field kind_of fun(err: any): string
---@field disk string
---@field doing string
---@field ended boolean Позвали `finish` либо `abort`
local Writer = {}
Writer.__index = Writer

--- Оборачивает писателя драйвера.
---@param inner any Писатель драйвера
---@param kind_of fun(err: any): string Род диска по отказу драйвера
---@param disk string Имя диска
---@param path string
---@param doing string Что не удалось бы, словами
---@return TntFilesWriter
function Module.new(inner, kind_of, disk, path, doing)
    return setmetatable(
        { path = path, inner = inner, kind_of = kind_of, disk = disk, doing = doing, ended = false },
        Writer
    )
end

--- Итог писателя драйвера: удача — `true`, отказ — родом диска.
---@param writer TntFilesWriter
---@param done any
---@param err any
---@return true|nil ok
---@return TntFilesFailure|nil err
local function outcome(writer, done, err)
    if not done then
        return nil, failure.of(writer.kind_of, writer.disk, writer.path, writer.doing, err)
    end

    return true
end

--- Бросает, если запись уже кончена: запись после `finish` или `abort` —
--- ошибка программиста, и винит она того, кто позвал писателя диска.
---@param writer TntFilesWriter
---@param action string
local function check_open(writer, action)
    if writer.ended then
        error(
            ('%s: запись файла %s на диске %s уже кончена'):format(
                action,
                writer.path,
                writer.disk
            ),
            3
        )
    end
end

--- Дописывает кусок.
---@param chunk string
---@return true|nil ok
---@return TntFilesFailure|nil err
function Writer:write(chunk)
    must.at(2).string(chunk, 'кусок')
    check_open(self, 'write')

    return outcome(self, self.inner:write(chunk))
end

--- Кончает запись: файл встаёт на место целиком. Отказ тоже кончает
--- запись — черновик убран, и писать дальше некуда.
---@return true|nil ok
---@return TntFilesFailure|nil err
function Writer:finish()
    check_open(self, 'finish')

    self.ended = true

    return outcome(self, self.inner:finish())
end

--- Бросает запись: файла не будет. Отказ самого бросания — пара:
--- у ведра начатая загрузка тогда осталась.
---@return true|nil ok
---@return TntFilesFailure|nil err
function Writer:abort()
    self.ended = true

    return outcome(self, self.inner:abort())
end

return Module
