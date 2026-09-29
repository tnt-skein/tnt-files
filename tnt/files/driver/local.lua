--- Драйвер `local`: файлы в каталоге узла через `tnt-fs`.
---
--- Путь диска приставляется к корню каталога. Всё, что пакет `tnt-fs`
--- обещает, достаётся диску как есть: запись атомарна и сбрасывается
--- на диск, чтение и запись кусками идут пулом нитей `fio` с уступкой,
--- и ни одно действие не держит узел.
---
--- Чтобы договор был одним и тем же у каталога и у ведра, драйвер делает
--- три вещи сверх `tnt-fs`:
---
--- * промежуточные каталоги под файлом заводит сам: у ведра их нет,
---   и `put('a/b/c.txt')` там просто работает;
--- * каталог по пути — не файл: его «нет» у чтения, размера и копии,
---   как у ведра нет объекта по приставке;
--- * удаление того, чего нет, — удача, как у ведра.
---
--- Ссылку со сроком на файл узла подписывает тот, кто файл раздаёт:
--- функция `sign(path, expires)` из настроек — обычно `signed_url` роутера
--- с маршрутом раздачи. Без неё ссылки со сроком у диска нет.

local fio = require('fio')
local fs = require('tnt.fs')

local failure = require('tnt.files.failure')

local Module = {}

--- Род диска по роду отказа `tnt-fs`; прочее — `failed`.
local KINDS = {
    [fs.MISSING] = failure.MISSING,
    [fs.DENIED] = failure.DENIED,
    [fs.FULL] = failure.FULL,
}

---@class TntFilesLocal Драйвер local
---@field name string
---@field temporary boolean Подписывает ли ссылки со сроком
---@field root string Каталог
---@field sign function|nil
local Local = {}
Local.__index = Local

--- Род диска по отказу драйвера.
---@param err any
---@return string
function Local.kind(err)
    return KINDS[err.kind] or failure.FAILED
end

--- Заводит драйвер. Каталога не трогает: корень заведёт первая запись.
---@param settings TntFilesDiskSettings
---@return TntFilesLocal
function Module.new(settings)
    return setmetatable({
        name = 'local',
        temporary = settings.sign ~= nil,
        root = settings.root,
        sign = settings.sign,
    }, Local)
end

--- Путь файла на узле. Склейка `fio` сводит «//» в одну черту: корень
--- с «/» на конце и корень `/` дают тот же путь, что и без неё.
---@param driver TntFilesLocal
---@param path string
---@return string
local function place(driver, path)
    return fio.pathjoin(driver.root, path)
end

--- Сведения о файле; нет файла — пусто без отказа.
---
--- Каталог по пути — тоже пусто: у ведра по приставке объекта нет,
--- и договор диска у каталога и у ведра один.
---@param full string
---@return TntFsStat|nil stat
---@return TntFsFailure|nil err
local function file_at(full)
    local stat, err = fs.stat(full)

    if stat == nil then
        ---@cast err TntFsFailure
        return nil, err.kind ~= fs.MISSING and err or nil
    end

    if stat.kind ~= 'file' then
        return nil
    end

    return stat
end

--- Заводит каталоги под файлом.
---@param full string
---@return true|nil ok
---@return TntFsFailure|nil err
local function room(full)
    return fs.make_tree(fio.dirname(full))
end

---@param path string
---@return string|nil content
---@return TntFsFailure|nil err
function Local:get(path)
    local full = place(self, path)
    local stat, err = file_at(full)

    if stat == nil then
        return nil, err
    end

    return fs.read(full)
end

---@param path string
---@return TntFsReader|nil reader
---@return TntFsFailure|nil err
function Local:reader(path)
    local full = place(self, path)
    local stat, err = file_at(full)

    if stat == nil then
        return nil, err
    end

    return fs.reader(full)
end

---@param path string
---@return TntFsWriter|nil writer
---@return TntFsFailure|nil err
function Local:writer(path)
    local full = place(self, path)
    local made, err = room(full)

    if not made then
        return nil, err
    end

    return fs.writer(full)
end

---@param path string
---@param content string
---@return true|nil ok
---@return TntFsFailure|nil err
function Local:put(path, content)
    local full = place(self, path)
    local made, err = room(full)

    if not made then
        return nil, err
    end

    return fs.replace(full, content)
end

---@param path string
---@return boolean|nil found
---@return TntFsFailure|nil err
function Local:exists(path)
    local stat, err = file_at(place(self, path))

    if err ~= nil then
        return nil, err
    end

    return stat ~= nil
end

---@param path string
---@return true|nil ok
---@return TntFsFailure|nil err
function Local:delete(path)
    local full = place(self, path)
    local stat, err = file_at(full)

    if err ~= nil then
        return nil, err
    end

    if stat == nil then
        return true
    end

    return fs.remove(full)
end

--- Копия кусками: читатель источника в писатель копии, в памяти один кусок.
---@param from string
---@param to string
---@return true|nil ok
---@return TntFsFailure|nil err
function Local:copy(from, to)
    local reader, err = self:reader(from)

    if reader == nil then
        return nil, err
    end

    local writer, unwritten = self:writer(to)

    if writer == nil then
        reader:close()

        return nil, unwritten
    end

    return fs.pipe(reader, writer)
end

--- Перенос переименованием: в пределах тома он атомарен и не копирует байты.
---@param from string
---@param to string
---@return true|nil ok
---@return TntFsFailure|nil err
function Local:move(from, to)
    local source = place(self, from)
    local stat, err = file_at(source)

    if stat == nil then
        return nil, err
    end

    local target = place(self, to)
    local made, unmade = room(target)

    if not made then
        return nil, unmade
    end

    return fs.rename(source, target)
end

---@param path string
---@return number|nil size
---@return TntFsFailure|nil err
function Local:size(path)
    local stat, err = file_at(place(self, path))

    if stat == nil then
        return nil, err
    end

    return stat.size
end

--- Ссылка со сроком — подписью того, кто раздаёт файлы.
---@param path string
---@param expires integer
---@return string|nil url
---@return any err
function Local:temporary_url(path, expires)
    -- Без подписи диск сюда не пускает: `temporary` у драйвера ложно.
    local sign = self.sign --[[@as function]]

    return sign(path, expires)
end

return Module
