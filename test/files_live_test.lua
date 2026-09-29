--- Диски против настоящих хранилищ: каталог узла и Garage стенда.
---
--- Что проверяется обоими драйверами одним и тем же кодом:
---
--- * файл в 50 МБ пишется и читается потоком, и память узла не растёт
---   вместе с файлом — прирост кучи Lua меньше половины файла;
--- * ссылка со сроком открывает файл, пока срок идёт, и не открывает
---   после: у ведра её подписывает само ведро, у каталога — роутер,
---   который файл и раздаёт;
--- * «нет файла» и «нет прав» — одни и те же роды отказа.
---
--- Сервер S3 поднимается отдельно — `make s3-up` (`test/stand/s3.sh`), —
--- и если его нет, проверки пропускаются: гейты не зависят от докера.

local digest = require('digest')
local fiber = require('fiber')
local fio = require('fio')
local http_client = require('http.client')
local http_server = require('http.server')
local t = require('luatest')
local uuid = require('uuid')

local helper = dofile('test/helper.lua')

local g, world = helper.group('tnt.files.live')

--- Окружение стенда — через `tnt-env`, как у проверок `tnt-s3`.
local env = helper.stand_env()

--- Где стоит сервер: тот же порт, что у скрипта стенда.
local PORT = env.int('STAND_S3_PORT', 19000)

--- Ключи стенда — те же, что заводит `test/stand/s3.sh`.
local STAND_KEY = 'GK746e742d7374616e642d7277'
local STAND_SECRET = 'db299f3310a74ee703523bb4d3a6df11a031668814c5af9568008e879cc7106f'
local READER_KEY = 'GK746e742d726561646f6e6c79'
local READER_SECRET = 'b047f9d1b3f5b3da0c3a97983c6837cc4bcb9e98e09356708db69bc2e3768b64'

--- Ключ подписи ссылок роутера: 32 байта, меньше роутер не берёт.
local SIGNING_KEY = ('k'):rep(32)

--- Кусок и число кусков файла: 64 КБ × 800 = 50 МБ.
local CHUNK = 64 * 1024
local CHUNKS = 800

--- Сколько куча Lua вправе удерживать сверх начала потока: меньше
--- половины файла. У ведра это часть загрузки либо кусок чтения по 8 МБ
--- и строки клиента HTTP вокруг них, у каталога — один кусок.
local GROWTH = 25 * 1024 * 1024

--- Раз в сколько байт потока мерить удержанное.
local EVERY = 2 * 1024 * 1024

g.before_all(function()
    t.skip_if(
        not helper.web.listening('127.0.0.1', PORT),
        'S3 не отвечает: поднимите его — make s3-up'
    )
end)

--- Клиент S3 стенда.
---@param key string|nil
---@param secret string|nil
---@return any
local function bucket(key, secret)
    return world.s3.new({
        endpoint = ('http://127.0.0.1:%d'):format(PORT),
        bucket = 'tnt-live',
        access_key = key or STAND_KEY,
        secret_key = secret or STAND_SECRET,
        timeout = 30,
    })
end

--- Файлы с двумя дисками: каталог проверки и ведро с приставкой прогона.
---@param extra table|nil Настройки локального диска сверх каталога
---@param client any|nil Клиент ведра; по умолчанию с правом записи
---@return any store
---@return string prefix Приставка ключей ведра
local function store_of(extra, client)
    local prefix = ('files-live/%s/'):format(uuid.str())

    return world.files.new({
        default = 'local',
        disks = {
            ['local'] = helper.web.merged({ driver = 'local', root = world.root }, extra),
            s3 = { driver = 's3', client = client or bucket(), prefix = prefix },
        },
    }),
        prefix
end

--- Мерило удержанной памяти: сколько кучи Lua остаётся после полной
--- сборки мусора сверх отметки начала потока.
---
--- Без сборки мерилась бы не память потока, а темп сборщика: мусор
--- кусков копится до следующего круга, и круг начинается, когда куча
--- удвоилась, — сколько бы ни весил поток.
---@return any measure `peak` — самое большое удержанное, `take(байты)` — отметить прошедшее
local function gauge()
    collectgarbage()

    local base = collectgarbage('count')
    ---@type any
    local measure = { peak = 0 }
    local passed = 0

    function measure.take(bytes)
        passed = passed + bytes

        if passed >= EVERY then
            passed = 0
            collectgarbage()
            measure.peak = math.max(measure.peak, (collectgarbage('count') - base) * 1024)
        end
    end

    return measure
end

--- Читатель, который выдаёт 50 МБ кусками, меряет удержанную память
--- и считает crc32 выданного.
---@return table reader
local function generator()
    ---@type any
    local reader = { given = 0, crc = digest.crc32.new(), gauge = gauge() }

    function reader.read()
        if reader.given == CHUNKS then
            return nil
        end

        reader.given = reader.given + 1

        local chunk = ('%08d'):format(reader.given):rep(CHUNK / 8)

        reader.crc:update(chunk)
        reader.gauge.take(#chunk)

        return chunk
    end

    function reader.close() end

    return reader
end

g.test_fifty_megabytes_stream_both_ways_without_the_memory_growing = function()
    local store = store_of()

    for _, name in ipairs({ 'local', 's3' }) do
        local disk = store:disk(name)
        local source = generator()

        t.assert_equals({ disk:put('поток/50mb.bin', source) }, { true }, name)
        t.assert_lt(source.gauge.peak, GROWTH, name .. ': запись')
        t.assert_equals(disk:size('поток/50mb.bin'), CHUNK * CHUNKS, name)

        local measure = gauge()
        local reader = disk:stream('поток/50mb.bin')
        local crc = digest.crc32.new()
        local total = 0

        while true do
            local chunk, err = reader:read()

            t.assert_equals(err, nil, name)

            if chunk == nil then
                break
            end

            total = total + #chunk
            crc:update(chunk)
            measure.take(#chunk)
        end

        t.assert_equals(total, CHUNK * CHUNKS, name)
        t.assert_equals(crc:result(), source.crc:result(), name)
        t.assert_lt(measure.peak, GROWTH, name .. ': чтение')
        t.assert_equals(disk:delete('поток/50mb.bin'), true, name)
    end
end

--- Сервер, который раздаёт файлы локального диска по ссылке с подписью.
---@param disk any
---@return any web Роутер
---@return any httpd Сервер
local function serving(router, disk)
    local web = router.new({ signing = { key = SIGNING_KEY } })
    local httpd = http_server.new('127.0.0.1', 0, { log_requests = false, log_errors = false, idle_timeout = 5 })

    web.get('/files/*path', function(request)
        local reader, err = disk:stream(request.params.path)

        if reader == nil then
            return nil, { status = err.kind == 'missing' and 404 or 500, reason = tostring(err) }
        end

        return router.stream(function()
            return reader:read()
        end, 200, { ['content-type'] = 'application/octet-stream' })
    end, { name = 'files', middleware = { web.signed() } })

    web.attach(httpd)
    httpd:start()

    return web, httpd
end

g.test_temporary_links_open_the_file_until_the_term = function()
    local router = helper.router()
    local signer = {}
    local store = store_of({
        sign = function(path, expires)
            return signer.address .. signer.web.signed_url('files', { path = path }, { expires = expires })
        end,
    })
    local web, httpd = serving(router, store:disk('local'))

    signer.web = web
    signer.address = ('http://127.0.0.1:%d'):format(httpd.tcp_server:name().port)

    local links = {}

    for _, name in ipairs({ 'local', 's3' }) do
        local disk = store:disk(name)

        t.assert_equals({ disk:put('ссылки/отчёт 1.txt', 'отчёт ' .. name) }, { true }, name)

        links[name] = disk:temporary_url('ссылки/отчёт 1.txt', 1)

        local answer = http_client.new():request('GET', links[name], nil, { timeout = 5 })

        t.assert_equals({ answer.status, answer.body }, { 200, 'отчёт ' .. name }, name)
    end

    -- Срок ссылки — целые секунды стенных часов: через две секунды он вышел
    -- у обеих. Роутер отвечает 403 `router_signature_expired`; служба S3 —
    -- своим отказом: AWS — 403 «Request has expired», Garage — 400 «Date
    -- is too old». Договор диска — «ссылка больше не открывает файл».
    fiber.sleep(2.1)

    for _, name in ipairs({ 'local', 's3' }) do
        local answer = http_client.new():request('GET', links[name], nil, { timeout = 5 })

        t.assert_items_include({ 400, 403 }, { answer.status }, name)
        t.assert_not_equals(answer.body, 'отчёт ' .. name, name)
        t.assert_equals(store:disk(name):delete('ссылки/отчёт 1.txt'), true, name)
    end

    httpd:stop()
end

g.test_missing_and_denied_are_the_same_kinds_on_both_drivers = function()
    local store = store_of()

    for _, name in ipairs({ 'local', 's3' }) do
        local disk = store:disk(name)

        t.assert_equals(select(2, disk:get('нет/файла.txt')).kind, 'missing', name)
        t.assert_equals(select(2, disk:stream('нет/файла.txt')).kind, 'missing', name)
        t.assert_equals(select(2, disk:size('нет/файла.txt')).kind, 'missing', name)
        t.assert_equals(select(2, disk:copy('нет/файла.txt', 'куда.txt')).kind, 'missing', name)
        t.assert_equals(select(2, disk:move('нет/файла.txt', 'куда.txt')).kind, 'missing', name)
        t.assert_equals(disk:exists('нет/файла.txt'), false, name)
        t.assert_equals(disk:delete('нет/файла.txt'), true, name)
    end

    -- Нет прав: каталог только для чтения и ключ только для чтения.
    local readonly = store_of(nil, bucket(READER_KEY, READER_SECRET))

    fio.chmod(world.root, tonumber('555', 8) --[[@as integer]])

    for _, name in ipairs({ 'local', 's3' }) do
        local ok, err = readonly:disk(name):put('нельзя.txt', 'x')

        t.assert_equals({ ok, err.kind }, { nil, 'denied' }, name)
        t.assert_str_contains(
            err.message,
            ('диск %s: файл нельзя.txt не записан: '):format(name)
        )
    end

    fio.chmod(world.root, tonumber('755', 8) --[[@as integer]])
end

g.test_copy_and_move_keep_the_content_on_both_drivers = function()
    local store = store_of()

    for _, name in ipairs({ 'local', 's3' }) do
        local disk = store:disk(name)

        t.assert_equals({ disk:put('a/исходник.txt', 'данные') }, { true }, name)
        t.assert_equals({ disk:copy('a/исходник.txt', 'b/копия.txt') }, { true }, name)
        t.assert_equals({ disk:move('b/копия.txt', 'c/перенос.txt') }, { true }, name)
        t.assert_equals(disk:exists('b/копия.txt'), false, name)
        t.assert_equals(
            { disk:get('a/исходник.txt'), disk:get('c/перенос.txt') },
            { 'данные', 'данные' },
            name
        )

        for _, path in ipairs({ 'a/исходник.txt', 'c/перенос.txt' }) do
            disk:delete(path)
        end
    end
end
