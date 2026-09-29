--- Настройки дисков: проверка и приведение.
---
---     {
---         default = 'uploads',
---         disks = {
---             ['local'] = { driver = 'local', root = '/var/lib/app/storage', url = '/storage' },
---             uploads = { driver = 's3', client = bucket, prefix = 'uploads/', url = 'https://cdn.example.org' },
---         },
---     }
---
--- Негодная настройка — исключение на строке того, кто завёл файлы: диски
--- заводят при подъёме узла, а первый файл кладут через час, и опечатка
--- `rooot` иначе молча оставила бы диск без каталога.

local must = require('tnt.must')

local Module = {}

--- Драйверы по порядку — для отказа о незнакомом.
Module.DRIVERS = { 'local', 's3' }

--- Чем называются настройки в отказе.
local TITLE = 'настройки файлов'

--- Настройки целиком.
local OPTIONS = { default = '?not_empty', disks = 'table' }

--- Настройки диска по драйверу.
---
--- `sign` — только у локального: ссылку со сроком на файл узла подписывает
--- тот, кто его раздаёт, а у ведра ссылку подписывает само ведро.
local SPECS = {
    ['local'] = { driver = 'string', root = 'not_empty', url = '?not_empty', sign = '?callable' },
    s3 = { driver = 'string', client = 'table', prefix = '?string', url = '?not_empty' },
}

---@class TntFilesDiskOptions Настройки диска
---@field driver string `local` либо `s3`
---@field root string|nil Каталог диска — у `local`
---@field sign (fun(path: string, expires: integer): string|nil, any)|nil Подпись ссылки со сроком — у `local`
---@field client TntS3Client|nil Клиент `tnt-s3` — у `s3`
---@field prefix string|nil Приставка ключей в ведре — у `s3`; пусто либо с «/» на конце
---@field url string|nil Публичный адрес, под которым видны пути диска

---@class TntFilesOptions Настройки файлов
---@field default string|nil Диск по умолчанию; при одном диске — он
---@field disks table<string, TntFilesDiskOptions> Диски по именам

---@class TntFilesDiskSettings Проверенные настройки диска
---@field driver string
---@field root string|nil Каталог
---@field sign function|nil
---@field client TntS3Client|nil
---@field prefix string Приставка ключей; пусто — без неё
---@field url string|nil Адрес без «/» на конце

--- Строка без «/» на конце.
---
--- Циклом, а не образцом: у образца, привязанного к концу строки, жадный
--- и ленивый повтор снимают одно и то же, и такая строка выглядела бы
--- проверенной, не будучи ею.
---@param text string
---@return string
local function trimmed(text)
    while text:sub(-1) == '/' do
        text = text:sub(-#text, -2)
    end

    return text
end

--- Проверяет публичный адрес и снимает «/» на конце.
---
--- Годится полный адрес `http(s)://узел/путь` и путь от корня сайта
--- `/storage`: файлы локального диска чаще раздаёт само приложение.
--- Строка запроса и обрывок не годятся — к ним путь файла не приставить.
---@param url string
---@param name string
---@param level integer
---@return string
local function checked_url(url, name, level)
    local absolute = url:find('^https?://[^/?#]') ~= nil or url:find('^/') ~= nil

    if not absolute or url:find('[?#%s]') ~= nil then
        error(
            ('%s — адрес http(s)://узел[/путь] либо /путь без строки запроса, а не «%s»'):format(
                name,
                url
            ),
            level + 1
        )
    end

    return trimmed(url)
end

--- Проверяет приставку ключей: пусто либо отрезки с «/» на конце.
---@param prefix string
---@param name string
---@param level integer
local function check_prefix(prefix, name, level)
    if prefix ~= '' and (prefix:find('/$') == nil or ('/' .. prefix):find('/%.?%.?/') ~= nil) then
        error(
            ('%s — пусто либо отрезки через «/» с «/» на конце, без «.» и «..», а не «%s»'):format(
                name,
                prefix
            ),
            level + 1
        )
    end
end

--- Проверяет настройки одного диска.
---@param name any Имя диска
---@param disk any
---@param level integer
---@return TntFilesDiskSettings
local function checked_disk(name, disk, level)
    local caller = must.at(level + 1)
    local title = ('%s.disks.%s'):format(TITLE, tostring(name))

    caller.not_empty(name, ('%s.disks: имя диска'):format(TITLE))
    caller.table(disk, title)
    caller.one_of(disk.driver, title .. '.driver', Module.DRIVERS)
    caller.options(disk, title, SPECS[disk.driver])

    local prefix = disk.prefix or ''

    check_prefix(prefix, title .. '.prefix', level + 1)

    return {
        driver = disk.driver,
        root = disk.root,
        sign = disk.sign,
        client = disk.client,
        prefix = prefix,
        url = disk.url and checked_url(disk.url, title .. '.url', level + 1),
    }
end

--- Имена дисков по порядку — для отказа об имени, которого нет.
---@param disks table
---@return string
function Module.names(disks)
    local names = {}

    for name in pairs(disks) do
        table.insert(names, name)
    end

    table.sort(names)

    return table.concat(names, ', ')
end

--- Проверяет настройки файлов.
---@param opts any
---@param level integer Уровень вины в кадрах того, кто зовёт
---@return { default: string, disks: table<string, TntFilesDiskSettings> }
function Module.check(opts, level)
    must.at(level + 1).options(opts, TITLE, OPTIONS)

    local disks = {}
    local count = 0

    for name, disk in pairs(opts.disks) do
        disks[name] = checked_disk(name, disk, level + 1)
        count = count + 1
    end

    local default = opts.default

    if count == 0 then
        error(('%s.disks — хоть один диск, а не пустая таблица'):format(TITLE), level + 1)
    end

    if default == nil and count > 1 then
        error(
            ('%s.default — имя диска по умолчанию: дисков несколько (%s)'):format(
                TITLE,
                Module.names(disks)
            ),
            level + 1
        )
    end

    default = default or next(disks)

    if disks[default] == nil then
        error(
            ('%s.default — одно из: %s, а не «%s»'):format(TITLE, Module.names(disks), tostring(default)),
            level + 1
        )
    end

    return { default = default, disks = disks }
end

return Module
