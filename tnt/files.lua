--- Файлы приложения: диски со сменными драйверами за одним договором.
---
---     local files = require('tnt.files')
---
---     local store = files.new({
---         default = 'local',
---         disks = {
---             ['local'] = { driver = 'local', root = '/var/lib/app/storage', url = '/storage' },
---             uploads = { driver = 's3', client = bucket, prefix = 'uploads/', url = 'https://cdn.example.org' },
---         },
---     })
---
---     local disk = store:disk('uploads')                  -- без имени — диск по умолчанию
---     disk:put('avatars/7.png', png, { type = 'image/png' })
---     disk:put('exports/big.csv', fs.reader('/tmp/big.csv'))   -- кусками
---     local content, err = disk:get('avatars/7.png')     -- нет файла — err.kind == 'missing'
---     local link = disk:temporary_url('avatars/7.png', 600)
---
--- Файлы узла и объекты в ведре — два разных предмета с разными отказами:
--- у `tnt-fs` свои роды и `errno`, у `tnt-s3` — коды ответа и промах без
--- отказа. Прикладной код, который пишет загрузку посетителя, не должен
--- знать, куда она ляжет: место выбирает настройка, а код одинаков.
--- Поэтому здесь диск — один договор (`tnt.files.disk`), а под ним драйвер:
---
--- * `local` — каталог узла через `tnt-fs` (`tnt.files.driver.local`);
--- * `s3` — ведро через клиент `tnt-s3`, пришедший настройкой `client`
---   (`tnt.files.driver.s3`): клиент заводит приложение, а пакет от `tnt-s3`
---   не зависит.
---
--- Отказ — пара `nil, err`, род у всех драйверов один (`tnt.files.failure`):
--- `missing`, `denied`, `full`, `unavailable`, `failed`. Исключение —
--- ошибка программиста: негодная настройка, незнакомый диск, негодный путь.
---
--- Подробно — `docs/files.md`.

local must = require('tnt.must')

local disk_of = require('tnt.files.disk')
local failure = require('tnt.files.failure')
local settings_of = require('tnt.files.settings')

local Module = {}

--- Файла нет.
Module.MISSING = failure.MISSING

--- Нет прав.
Module.DENIED = failure.DENIED

--- Кончилось место.
Module.FULL = failure.FULL

--- Хранилище сейчас не отвечает: время это лечит.
Module.UNAVAILABLE = failure.UNAVAILABLE

--- Прочее.
Module.FAILED = failure.FAILED

--- Отказ ли это диска.
Module.is_failure = failure.is

--- Драйверы по имени. Модуль грузится вместе с пакетом: оба лёгкие,
--- а драйвер `s3` сам клиента не заводит — его приносит настройка.
local DRIVERS = {
    ['local'] = require('tnt.files.driver.local'),
    s3 = require('tnt.files.driver.s3'),
}

---@class TntFiles Файлы приложения: диски по именам
---@field default string Имя диска по умолчанию
---@field private disks table<string, TntFilesDisk>
local Store = {}
Store.__index = Store

--- Заводит диски. В сеть и на диск не ходит: каталог локального диска
--- заведёт первая запись, ведро спросит первый вызов.
---@param opts TntFilesOptions
---@return TntFiles
function Module.new(opts)
    local settings = settings_of.check(opts, 2)
    local disks = {}

    for name, disk in pairs(settings.disks) do
        -- Имя драйвера уже сверено со списком: драйвер по нему есть всегда.
        local driver = DRIVERS[disk.driver] --[[@as any]]

        disks[name] = disk_of.new(name, disk, driver.new(disk))
    end

    return setmetatable({ default = settings.default, disks = disks }, Store)
end

--- Диск по имени; без имени — диск по умолчанию.
---
--- Незнакомое имя — исключение: имя диска пишет программист, и опечатка
--- в нём должна падать на первом вызове, а не класть файл неизвестно куда.
---@param name string|nil
---@return TntFilesDisk
function Store:disk(name)
    must.at(2).optional.not_empty(name, 'имя диска')

    local found = self.disks[name or self.default]

    if found == nil then
        error(('диска «%s» нет: есть %s'):format(name, settings_of.names(self.disks)), 2)
    end

    return found
end

return Module
