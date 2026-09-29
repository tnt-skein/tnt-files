--- Общие средства проверок файлов приложения.
---
--- Локальный диск проверяется на настоящем каталоге — у каждой проверки
--- свой, — а ведро — настоящим клиентом `tnt-s3` на двойнике libcurl: так
--- видно и то, что уходит службе, и то, как её ответ становится отказом
--- диска. Поведение настоящей службы проверяет `files_live_test.lua`
--- против Garage стенда.
---
--- Исходники пакета читаются с диска, а не через `require`: у Tarantool
--- свой загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt-must` и `tnt-fs` — берутся из `.rocks` обычным `require`:
--- проверяется этот пакет, а не они.
---
--- Соседи проверок стоят в `.rocks` (`make deps`) и зависимостями пакета
--- не объявлены: клиент ведра `tnt-s3` (с ним приходят `tnt-http`,
--- `tnt-retry` и `tnt-storage`, в которых проверки ставят двойники),
--- роутер `tnt-router`, который раздаёт файлы каталога по ссылке
--- со сроком, и чтение окружения `tnt-env` для порта стенда. Все они —
--- один экземпляр на процесс: подмену, поставленную проверкой, снимает
--- `restore`, иначе она пережила бы проверку и сломала бы соседние.
---
--- Оснастка в `test/testing/` — загрузчик исходников и сценарий ответов —
--- грузится так же, файлами, и один раз на процесс: второй экземпляр
--- загрузчика не знал бы, что вытеснил первый, и не вернул бы вытесненное
--- на место.
---
--- Проверки берут всё через этот помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же файла
--- там, где пакет живёт рядом со своими зависимостями.

local fio = require('fio')
local socket = require('socket')
local t = require('luatest')

--- Модули оснастки в порядке зависимостей.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.protocol', path = 'test/testing/protocol.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    unload_sources = package.loaded['tnt.testing.sources'].unload,
    module = package.loaded['tnt.testing.sources'].module,
    script = package.loaded['tnt.testing.protocol'].script,
}

local helper = {
    --- Модули пакета в порядке зависимостей.
    MODULES = {
        { name = 'tnt.files.failure', path = 'tnt/files/failure.lua' },
        { name = 'tnt.files.settings', path = 'tnt/files/settings.lua' },
        { name = 'tnt.files.reader', path = 'tnt/files/reader.lua' },
        { name = 'tnt.files.writer', path = 'tnt/files/writer.lua' },
        { name = 'tnt.files.driver.local', path = 'tnt/files/driver/local.lua' },
        { name = 'tnt.files.driver.s3', path = 'tnt/files/driver/s3.lua' },
        { name = 'tnt.files.disk', path = 'tnt/files/disk.lua' },
        { name = 'tnt.files', path = 'tnt/files.lua' },
    },
}

--- Двойник libcurl под клиентом HTTP ведра и ответы сервера.
local web = {}

--- Настройки проверки поверх умолчаний: новая таблица, умолчания целы.
---@param defaults table
---@param overrides table|nil
---@return table
function web.merged(defaults, overrides)
    local merged = {}

    for _, given in ipairs({ defaults, overrides or {} }) do
        for name, value in pairs(given) do
            merged[name] = value
        end
    end

    return merged
end

--- Отвечает ли кто-нибудь на этом порту: живые проверки без стенда
--- пропускаются, а не падают.
---@param host string
---@param port integer
---@return boolean
function web.listening(host, port)
    local connection = socket.tcp_connect(host, port, 0.3)

    if connection == nil then
        return false
    end

    connection:close()

    return true
end

--- Ответ, который отдал бы настоящий сервер.
---
--- Заголовки приходят как есть, в том числе с заглавными буквами: чужой
--- сервер пишет их как вздумается, и приведение к нижнему регистру —
--- работа клиента, а не проверки.
---@param status integer
---@param overrides table|nil Поля поверх умолчаний
---@return table
function web.answer(status, overrides)
    return web.merged({ status = status, reason = 'Ok', headers = {}, body = '' }, overrides)
end

--- Ответ, которого не было: так `http.client` сообщает об отказе сети
--- до отправки — имя не разрешилось, соединение не открылось.
---
--- Заголовков нет вовсе, и это единственная надёжная примета: код 595
--- libcurl придумывает сам, и такой же мог бы придумать чужой сервер.
---@param reason string|nil
---@return table
function web.no_answer(reason)
    return { status = 595, reason = reason or 'Could not resolve hostname' }
end

--- Ставит двойник libcurl на место настоящего.
---
--- Двойник помнит, о чём его просили, и отдаёт заранее написанные ответы
--- по порядку: какой запрос ушёл службе, видно только по нему.
---@param script table[] Ответы по порядку
---@return table sent Что уходило на сервер
function web.serving(script)
    local sent = {}
    local answers = testing.script(script)

    local handle = {
        request = function(_, method, url, body, options)
            table.insert(sent, { method = method, url = url, body = body, options = options })

            -- Кончившийся сценарий — ошибка проверки: клиент, сходивший
            -- к серверу лишний раз, обязан об этом сказать.
            return answers.next()
        end,
    }

    require('tnt.http.transport')._set_source({
        client = function()
            return handle
        end,
    })

    return sent
end

--- Части пакета и соседи текущей проверки: заполняются заново перед каждой.
---
--- Таблица одна на файл, а не ссылки, взятые при загрузке: исходники
--- грузятся заново перед каждой проверкой, и диск, собранный из прошлой
--- загрузки, остался бы со ссылками на прежние модули.
---@type table
local world = {}

--- Загружает исходники заново, заводит каталог проверки и маску `022`.
---
--- Маска ставится явно: права новых файлов сверяются числом, а маска
--- у машины, на которой гоняют проверки, бывает любой.
---@return table world
function helper.fresh()
    world.files = testing.load_sources(helper.MODULES, 'tnt.files')
    world.fs = require('tnt.fs')
    world.s3 = require('tnt.s3')
    world.failure = testing.module('tnt.files.failure')
    world.root = fio.tempdir()
    world.umask = fio.umask(tonumber('022', 8) --[[@as integer]])

    return world
end

--- Роутер: файлы локального диска по ссылке со сроком раздаёт он.
---
--- Из `.rocks`, один на процесс: проверка ничего в нём не подменяет,
--- и снимать после неё нечего.
---@return table router
function helper.router()
    return require('tnt.router')
end

--- Чтение окружения для настроек живых проверок: порт стенда.
---@return table
function helper.stand_env()
    return require('tnt.env')
end

--- Внешние зависимости соседей, которые подменяют проверки: часы срока,
--- libcurl и паузы повторов.
---
--- Снимаются все разом и по списку: снятую поимённо зависимость однажды
--- забудут, и следующая проверка пойдёт с чужим двойником.
local SEAMS = { 'tnt.s3', 'tnt.fs', 'tnt.storage.within', 'tnt.http.transport', 'tnt.retry.runner' }

--- Возвращает настоящие часы, сеть и диск, сносит каталог проверки
--- и убирает исходники.
function helper.restore()
    for _, name in ipairs(SEAMS) do
        require(name)._set_source(nil)
    end

    fio.umask(world.umask)
    fio.rmtree(world.root)
    testing.unload_sources(helper.MODULES)
end

--- Группа проверок: исходники и каталог — свои у каждой проверки.
---@param name string
---@return table g Группа luatest
---@return table world
function helper.group(name)
    local g = t.group(name)

    g.before_each(helper.fresh)
    g.after_each(function()
        helper.restore()
    end)

    return g, world
end

--- Двойник libcurl и ответы сервера.
helper.web = web

--- Ответ S3 с отказом.
---@param status integer
---@param code string
---@param message string
---@return table
function helper.fault(status, code, message)
    return web.answer(status, {
        headers = { ['Content-Type'] = 'application/xml' },
        body = (
            '<?xml version="1.0" encoding="UTF-8"?>\n<Error><Code>%s</Code><Message>%s</Message>'
            .. '<RequestId>4442587FB7D0A2F9</RequestId></Error>'
        ):format(code, message),
    })
end

--- Сверяет, что каждый вызов бросает названный отказ и винит строку
--- вызова в файле проверок, а не внутри пакета.
---
--- Вызов стоит в замыкании первой строкой тела, то есть строкой ниже
--- слова `function`: место броска сверяется с ней целиком — файлом,
--- строкой и текстом.
---@param cases table[] Пары: замыкание с вызовом и текст броска
function helper.assert_blamed(cases)
    for _, case in ipairs(cases) do
        local _, err = pcall(case[1])
        local info = debug.getinfo(case[1], 'S') --[[@as { short_src: string, linedefined: integer }]]

        t.assert_equals(err, ('%s:%d: %s'):format(info.short_src, info.linedefined + 1, case[2]))
    end
end

--- Значение мимо проверки типов: негодный аргумент нарочно.
---@param value any
---@return any
function helper.wrong(value)
    return value
end

--- Ключ из примеров AWS: подпись с ним сверяется с документацией дословно.
local ACCESS_KEY = 'AKIAIOSFODNN7EXAMPLE'
local SECRET_KEY = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'

--- Миг подписи проверок: 2013-05-24T00:00:00Z, как в примерах AWS.
local NOW = 1369353600

--- Клиент S3 на двойнике: повторов нет, чтобы отказ приходил с первого
--- ответа, а часы подписи стоят.
---@param script table[] Ответы сервера по порядку
---@param overrides table|nil
---@return TntS3Client client
---@return table sent Что уходило на сервер
function helper.client(script, overrides)
    local sent = web.serving(script)

    world.s3._set_source({
        now = function()
            return NOW
        end,
    })

    return world.s3.new(web.merged({
        endpoint = 'http://127.0.0.1:9000',
        bucket = 'tnt-live',
        access_key = ACCESS_KEY,
        secret_key = SECRET_KEY,
        retry = { attempts = 1 },
    }, overrides)),
        sent
end

--- Путь в каталоге проверки.
---@param name string
---@return string
function helper.at(name)
    return fio.pathjoin(world.root, name)
end

--- Кладёт файл настоящим `fio`, мимо пакета.
---@param path string
---@param content string
function helper.put(path, content)
    fio.mktree(fio.dirname(path))

    local file = fio.open(path, { 'O_WRONLY', 'O_CREAT', 'O_TRUNC' }, tonumber('644', 8))

    file:write(content)
    file:close()
end

--- Читает файл настоящим `fio`, мимо пакета.
---@param path string
---@return string|nil
function helper.get(path)
    local file = fio.open(path, { 'O_RDONLY' })

    if file == nil then
        return nil
    end

    local content = file:read()

    file:close()

    return content
end

--- Все куски читателя до конца: договор читателя у файла, у ведра
--- и у диска один, и читается он этим же.
---@param reader any
---@return string[] chunks
---@return any err Чем кончилось чтение
function helper.drain(reader)
    local chunks = {}
    local chunk, err = reader:read()

    while chunk ~= nil do
        table.insert(chunks, chunk)
        chunk, err = reader:read()
    end

    return chunks, err
end

--- Сверяет отказ диска: род, текст и путь.
---@param err any
---@param kind string
---@param message string
function helper.assert_failure(err, kind, message)
    t.assert(world.failure.is(err), tostring(err))
    t.assert_equals({ err.kind, err.message }, { kind, message })
end

return helper
