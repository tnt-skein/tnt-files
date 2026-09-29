--- Файлы приложения: настройки дисков, выбор диска, отказ, пути, адреса.

local json = require('json')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local g, world = helper.group('tnt.files')

--- Файлы с одним локальным диском в каталоге проверки.
---@param extra table|nil Настройки диска поверх каталога
---@return any store
local function single(extra)
    return world.files.new({
        disks = { ['local'] = helper.web.merged({ driver = 'local', root = world.root }, extra) },
    })
end

g.test_single_disk_is_the_default = function()
    local store = single()

    t.assert_equals(store.default, 'local')
    t.assert_is(store:disk(), store:disk('local'))
    t.assert_equals({ store:disk().name, store:disk().driver }, { 'local', 'local' })
end

g.test_default_is_named_among_several = function()
    local client = helper.client({})
    local store = world.files.new({
        default = 'uploads',
        disks = {
            ['local'] = { driver = 'local', root = world.root },
            uploads = { driver = 's3', client = client, prefix = 'uploads/' },
        },
    })

    t.assert_equals({ store:disk().name, store:disk().driver }, { 'uploads', 's3' })
    t.assert_equals(store:disk('local').driver, 'local')
end

g.test_kinds_are_named_on_the_facade = function()
    t.assert_equals(
        { world.files.MISSING, world.files.DENIED, world.files.FULL, world.files.UNAVAILABLE, world.files.FAILED },
        { 'missing', 'denied', 'full', 'unavailable', 'failed' }
    )
end

g.test_failure_reads_as_its_text = function()
    local _, err = single():disk():get('нет.txt')
    local text = 'диск local: файл нет.txt не прочитан: файла нет'

    t.assert_equals({ err.kind, err.disk, err.path, err.cause }, { 'missing', 'local', 'нет.txt', nil })
    t.assert_equals(tostring(err), text)
    t.assert_equals('причина: ' .. err, 'причина: ' .. text)
    t.assert_equals(err .. '!', text .. '!')
    t.assert_equals(json.encode({ err = err }), json.encode({ err = text }))
    t.assert(world.files.is_failure(err))
    t.assert_not(world.files.is_failure({ kind = 'missing' }))
end

g.test_url_joins_the_address_and_the_encoded_path = function()
    local store = world.files.new({
        default = 'local',
        disks = {
            ['local'] = { driver = 'local', root = world.root, url = '/storage/' },
            cdn = { driver = 'local', root = world.root, url = 'https://cdn.example.org/files//' },
        },
    })

    t.assert_equals(store:disk():url('a b/отчёт~1.pdf'), '/storage/a%20b/%D0%BE%D1%82%D1%87%D1%91%D1%82~1.pdf')
    t.assert_equals(store:disk('cdn'):url('x-y_z.1'), 'https://cdn.example.org/files/x-y_z.1')
end

g.test_url_without_an_address_blames_the_caller = function()
    local disk = single():disk()

    helper.assert_blamed({
        {
            function()
                disk:url('a.txt')
            end,
            'у диска local нет публичного адреса — настройка url',
        },
    })
end

g.test_root_with_trailing_slashes_gives_the_same_paths = function()
    local disk = single({ root = world.root .. '//' }):disk()

    t.assert_equals({ disk:put('a.txt', 'x') }, { true })
    t.assert_equals(helper.get(helper.at('a.txt')), 'x')

    -- Путь на узле — в отказе `tnt-fs`: без двойной черты.
    local _, err = disk:put('a.txt/b.txt', 'x')

    t.assert_equals(err.cause.path, helper.at('a.txt'))
end

g.test_wrong_paths_blame_the_caller = function()
    local disk = single():disk()
    local rule =
        'путь — отрезки через «/» без пустых, «.», «..» и управляющих знаков, а не «%s»'
    local cases = {
        {
            function()
                disk:get(helper.wrong(7))
            end,
            'путь — непустая строка, а не число',
        },
        {
            function()
                disk:get('')
            end,
            'путь — непустая строка, а не пустая',
        },
        {
            function()
                disk:get(('a'):rep(1025))
            end,
            'путь длиннее 1024 байт: 1025',
        },
    }

    for _, path in ipairs({ '/a', 'a/', 'a//b', '.', '..', './a', 'a/./b', 'a/..', 'a\0b', 'a\nb', 'a\127' }) do
        table.insert(cases, {
            function()
                disk:exists(path)
            end,
            rule:format(path),
        })
    end

    helper.assert_blamed(cases)
end

g.test_names_with_dots_and_the_longest_path_pass = function()
    local disk = single():disk()

    -- Самый длинный путь — отрезками: у файловой системы узла свой предел
    -- на отрезок, 255 байт.
    local longest = (('a'):rep(99) .. '/'):rep(10) .. ('a'):rep(24)

    t.assert_equals(#longest, 1024)

    for _, path in ipairs({ '.hidden', 'a..b', '...', 'a/.b/c.', longest }) do
        t.assert_equals({ disk:exists(path) }, { false }, path)
    end
end

g.test_every_action_checks_its_arguments = function()
    local disk = single():disk()

    helper.assert_blamed({
        {
            function()
                disk:put('/a', 'x')
            end,
            'путь — отрезки через «/» без пустых, «.», «..» и управляющих знаков, а не «/a»',
        },
        {
            function()
                disk:put('a', 'x', { kind = 'text' })
            end,
            'настройки записи: ключа «kind» нет, есть type',
        },
        {
            function()
                disk:put('a', helper.wrong(7))
            end,
            'содержимое — таблица, а не число',
        },
        {
            function()
                disk:put('a', { client_name = 'кот.png', read = function() end })
            end,
            'содержимое — присланный файл, а не читатель: file.path — в fs.reader, file:read() — строкой',
        },
        {
            function()
                disk:writer('a/')
            end,
            'путь — отрезки через «/» без пустых, «.», «..» и управляющих знаков, а не «a/»',
        },
        {
            function()
                disk:writer('a', { type = '' })
            end,
            'настройки записи.type — непустая строка, а не пустая',
        },
        {
            function()
                disk:stream('')
            end,
            'путь — непустая строка, а не пустая',
        },
        {
            function()
                disk:delete('a//b')
            end,
            'путь — отрезки через «/» без пустых, «.», «..» и управляющих знаков, а не «a//b»',
        },
        {
            function()
                disk:copy('..', 'b')
            end,
            'откуда — отрезки через «/» без пустых, «.», «..» и управляющих знаков, а не «..»',
        },
        {
            function()
                disk:copy('a', '')
            end,
            'куда — непустая строка, а не пустая',
        },
        {
            function()
                disk:move('a', '/b')
            end,
            'куда — отрезки через «/» без пустых, «.», «..» и управляющих знаков, а не «/b»',
        },
        {
            function()
                disk:move('.', 'b')
            end,
            'откуда — отрезки через «/» без пустых, «.», «..» и управляющих знаков, а не «.»',
        },
        {
            function()
                disk:size('a/../b')
            end,
            'путь — отрезки через «/» без пустых, «.», «..» и управляющих знаков, а не «a/../b»',
        },
        {
            function()
                disk:url('')
            end,
            'путь — непустая строка, а не пустая',
        },
        {
            function()
                disk:temporary_url('/a', 60)
            end,
            'путь — отрезки через «/» без пустых, «.», «..» и управляющих знаков, а не «/a»',
        },
    })
end

g.test_temporary_link_needs_a_signer_and_a_term = function()
    local disk = single():disk()
    local signed = single({
        sign = function()
            return 'ссылка'
        end,
    }):disk()

    helper.assert_blamed({
        {
            function()
                disk:temporary_url('a', 60)
            end,
            'у диска local нет подписи ссылок со сроком — настройка sign',
        },
        {
            function()
                signed:temporary_url('a', 0)
            end,
            'срок ссылки — число от 1 до 604800, а не 0',
        },
        {
            function()
                signed:temporary_url('a', 604801)
            end,
            'срок ссылки — число от 1 до 604800, а не 604801',
        },
        {
            function()
                signed:temporary_url('a', 1.5)
            end,
            'срок ссылки — целое число, а не 1.5',
        },
    })
    t.assert_equals(signed:temporary_url('a', 1), 'ссылка')
    t.assert_equals(signed:temporary_url('a', 604800), 'ссылка')
end

g.test_unknown_disk_blames_the_caller = function()
    local store = single()

    helper.assert_blamed({
        {
            function()
                store:disk('uploads')
            end,
            'диска «uploads» нет: есть local',
        },
        {
            function()
                store:disk('')
            end,
            'имя диска — непустая строка, а не пустая',
        },
    })
end

g.test_wrong_settings_blame_the_caller = function()
    local client = helper.client({})
    local root = world.root

    --- Заводит файлы с настройками.
    local function new(opts)
        return function()
            world.files.new(opts)
        end
    end

    helper.assert_blamed({
        { new(helper.wrong(nil)), 'настройки файлов — таблица, а не nil' },
        {
            new({ disks = {}, extra = 1 }),
            'настройки файлов: ключа «extra» нет, есть default, disks',
        },
        {
            new({ disks = {} }),
            'настройки файлов.disks — хоть один диск, а не пустая таблица',
        },
        {
            new({ disks = { [1] = { driver = 'local', root = root } } }),
            'настройки файлов.disks: имя диска — непустая строка, а не число',
        },
        {
            new({ disks = { a = 'local' } }),
            'настройки файлов.disks.a — таблица, а не строка',
        },
        {
            new({ disks = { a = { driver = 'ftp' } } }),
            'настройки файлов.disks.a.driver — одно из «local», «s3», а не «ftp»',
        },
        {
            new({ disks = { a = { driver = 'local', root = root, client = client } } }),
            'настройки файлов.disks.a: ключа «client» нет, есть driver, root, sign, url',
        },
        {
            new({ disks = { a = { driver = 's3', client = client, root = root } } }),
            'настройки файлов.disks.a: ключа «root» нет, есть client, driver, prefix, url',
        },
        {
            new({ disks = { a = { driver = 'local' } } }),
            'настройки файлов.disks.a.root — непустая строка, а не nil',
        },
        {
            new({ disks = { a = { driver = 's3', client = client, prefix = 'uploads' } } }),
            'настройки файлов.disks.a.prefix — пусто либо отрезки через «/» с «/» на конце, без «.» и «..», '
                .. 'а не «uploads»',
        },
        {
            new({ disks = { a = { driver = 's3', client = client, prefix = '/uploads/' } } }),
            'настройки файлов.disks.a.prefix — пусто либо отрезки через «/» с «/» на конце, без «.» и «..», '
                .. 'а не «/uploads/»',
        },
        {
            new({ disks = { a = { driver = 's3', client = client, prefix = 'a/../' } } }),
            'настройки файлов.disks.a.prefix — пусто либо отрезки через «/» с «/» на конце, без «.» и «..», '
                .. 'а не «a/../»',
        },
        {
            new({ disks = { a = { driver = 'local', root = root, url = 'cdn.example.org' } } }),
            'настройки файлов.disks.a.url — адрес http(s)://узел[/путь] либо /путь без строки запроса, '
                .. 'а не «cdn.example.org»',
        },
        {
            new({ disks = { a = { driver = 'local', root = root, url = 'https:///x' } } }),
            'настройки файлов.disks.a.url — адрес http(s)://узел[/путь] либо /путь без строки запроса, '
                .. 'а не «https:///x»',
        },
        {
            new({ disks = { a = { driver = 'local', root = root, url = '/files?x=1' } } }),
            'настройки файлов.disks.a.url — адрес http(s)://узел[/путь] либо /путь без строки запроса, '
                .. 'а не «/files?x=1»',
        },
        {
            new({ disks = { a = { driver = 'local', root = root, url = '/files#top' } } }),
            'настройки файлов.disks.a.url — адрес http(s)://узел[/путь] либо /путь без строки запроса, '
                .. 'а не «/files#top»',
        },
        {
            new({ disks = { a = { driver = 'local', root = root, url = '/my files' } } }),
            'настройки файлов.disks.a.url — адрес http(s)://узел[/путь] либо /путь без строки запроса, '
                .. 'а не «/my files»',
        },
        {
            new({
                disks = {
                    a = { driver = 'local', root = root },
                    b = { driver = 'local', root = root },
                },
            }),
            'настройки файлов.default — имя диска по умолчанию: дисков несколько (a, b)',
        },
        {
            new({ default = 'c', disks = { a = { driver = 'local', root = root } } }),
            'настройки файлов.default — одно из: a, а не «c»',
        },
    })
end

g.test_good_prefixes_and_addresses_pass = function()
    local client = helper.client({})

    for _, prefix in ipairs({ '', 'a/', 'a/b/', '.x/' }) do
        world.files.new({ disks = { a = { driver = 's3', client = client, prefix = prefix } } })
    end

    for _, url in ipairs({ 'http://a', 'https://a.b:8080/x', '/' }) do
        world.files.new({ disks = { a = { driver = 'local', root = world.root, url = url } } })
    end
end
