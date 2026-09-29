--- Диск на драйвере local: договор диска на настоящем каталоге.

local errno = require('errno')
local fio = require('fio')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local g, world = helper.group('tnt.files.local')

--- Диск в каталоге проверки.
---@param extra table|nil
---@return any disk
local function disk_of(extra)
    return world.files
        .new({ disks = { ['local'] = helper.web.merged({ driver = 'local', root = world.root }, extra) } })
        :disk()
end

--- Подменяет в `fio` пакета `tnt-fs` названные действия.
---@param replaced table<string, function>
local function with_fio(replaced)
    world.fs._set_source({ fio = setmetatable(replaced, { __index = fio }) })
end

--- Открытие, которое отказывает кодом на пути внутри каталога проверки.
---@param code integer
---@return function
local function refusing_open(code)
    return function(path, flags, mode)
        if path:find(world.root, 1, true) == 1 and path ~= world.root then
            return nil, { errno = code }
        end

        return fio.open(path, flags, mode)
    end
end

g.test_put_and_get_a_file_with_its_directories = function()
    local disk = disk_of()

    t.assert_equals({ disk:put('avatars/7/кот.png', 'картинка', { type = 'image/png' }) }, { true })
    t.assert_equals(helper.get(helper.at('avatars/7/кот.png')), 'картинка')
    t.assert_equals(disk:get('avatars/7/кот.png'), 'картинка')
    t.assert_equals(disk:size('avatars/7/кот.png'), 16)
    t.assert_equals(disk:exists('avatars/7/кот.png'), true)
    t.assert_equals(fio.listdir(helper.at('avatars/7')), { 'кот.png' })
end

g.test_put_replaces_the_file = function()
    local disk = disk_of()

    helper.put(helper.at('a.txt'), 'старое')

    t.assert_equals({ disk:put('a.txt', 'новое') }, { true })
    t.assert_equals(disk:get('a.txt'), 'новое')
end

g.test_missing_file_is_missing_everywhere = function()
    local disk = disk_of()
    local calls = {
        {
            function()
                return disk:get('нет.txt')
            end,
            'диск local: файл нет.txt не прочитан: файла нет',
        },
        {
            function()
                return disk:stream('нет.txt')
            end,
            'диск local: файл нет.txt не прочитан: файла нет',
        },
        {
            function()
                return disk:size('нет.txt')
            end,
            'диск local: размер файла нет.txt не узнан: файла нет',
        },
        {
            function()
                return disk:copy('нет.txt', 'b.txt')
            end,
            'диск local: файл нет.txt не скопирован в b.txt: файла нет',
        },
        {
            function()
                return disk:move('нет.txt', 'b.txt')
            end,
            'диск local: файл нет.txt не перенесён в b.txt: файла нет',
        },
    }

    for _, call in ipairs(calls) do
        local value, err = call[1]()

        t.assert_equals(value, nil)
        helper.assert_failure(err, 'missing', call[2])
        t.assert_equals(err.path, 'нет.txt')
    end

    t.assert_equals(disk:exists('нет.txt'), false)
    t.assert_equals(fio.listdir(world.root), {})
end

g.test_a_directory_is_not_a_file = function()
    local disk = disk_of()

    fio.mktree(helper.at('папка/внутри'))

    t.assert_equals(disk:exists('папка'), false)
    t.assert_equals(select(2, disk:get('папка')).kind, 'missing')
    t.assert_equals(select(2, disk:stream('папка')).kind, 'missing')
    t.assert_equals(select(2, disk:size('папка')).kind, 'missing')
    t.assert_equals(select(2, disk:move('папка', 'b')).kind, 'missing')
    -- Удалять нечего: каталог не файл и остаётся на месте.
    t.assert_equals(disk:delete('папка'), true)
    t.assert(fio.path.is_dir(helper.at('папка/внутри')))
end

g.test_delete_removes_and_missing_is_success = function()
    local disk = disk_of()

    helper.put(helper.at('a/b.txt'), 'x')

    t.assert_equals(disk:delete('a/b.txt'), true)
    t.assert_equals(helper.get(helper.at('a/b.txt')), nil)
    t.assert_equals(disk:delete('a/b.txt'), true)
end

g.test_stream_gives_the_file_in_chunks = function()
    local disk = disk_of()

    helper.put(helper.at('big.bin'), ('x'):rep(world.fs.CHUNK) .. 'y')

    local reader = disk:stream('big.bin')
    local chunks, err = helper.drain(reader)

    t.assert_equals(err, nil)
    t.assert_equals({ #chunks, #chunks[1], chunks[2] }, { 2, world.fs.CHUNK, 'y' })
    t.assert_equals(reader.path, 'big.bin')
    t.assert_equals(reader:close(), true)
end

g.test_stream_failing_midway_is_a_failure_of_the_disk = function()
    local disk = disk_of()

    helper.put(helper.at('a.txt'), 'x')
    with_fio({
        open = function()
            return {
                read = function()
                    return nil, { errno = errno.EIO }
                end,
                close = function() end,
            }
        end,
    })

    local chunk, err = disk:stream('a.txt'):read()

    t.assert_equals(chunk, nil)
    helper.assert_failure(
        err,
        'failed',
        'диск local: файл a.txt не прочитан: ' .. errno.strerror(errno.EIO)
    )
    t.assert_equals(err.cause.errno, errno.EIO)
end

g.test_reading_after_close_blames_the_caller = function()
    local disk = disk_of()

    helper.put(helper.at('a.txt'), 'x')

    local reader = disk:stream('a.txt')

    reader:close()
    helper.assert_blamed({
        {
            function()
                reader:read()
            end,
            'read: чтение файла a.txt на диске local уже закрыто',
        },
    })
end

g.test_writer_puts_the_file_on_finish = function()
    local disk = disk_of()
    local writer = disk:writer('exports/2026.csv')

    t.assert_equals({ writer:write('a;b\n') }, { true })
    t.assert_equals({ writer:write('1;2\n') }, { true })
    t.assert_equals(helper.get(helper.at('exports/2026.csv')), nil)
    t.assert_equals({ writer:finish() }, { true })
    t.assert_equals(disk:get('exports/2026.csv'), 'a;b\n1;2\n')
    t.assert_equals(writer.path, 'exports/2026.csv')
end

g.test_writer_abort_leaves_nothing = function()
    local disk = disk_of()
    local writer = disk:writer('a.txt')

    writer:write('x')

    t.assert_equals({ writer:abort() }, { true })
    t.assert_equals(fio.listdir(world.root), {})
end

g.test_writer_after_the_end_blames_the_caller = function()
    local disk = disk_of()
    local finished = disk:writer('a.txt')
    local aborted = disk:writer('b.txt')

    finished:finish()
    aborted:abort()

    helper.assert_blamed({
        {
            function()
                finished:write('x')
            end,
            'write: запись файла a.txt на диске local уже кончена',
        },
        {
            function()
                finished:finish()
            end,
            'finish: запись файла a.txt на диске local уже кончена',
        },
        {
            function()
                aborted:write('x')
            end,
            'write: запись файла b.txt на диске local уже кончена',
        },
        {
            function()
                aborted:write(helper.wrong(1))
            end,
            'кусок — строка, а не число',
        },
    })
end

g.test_put_takes_a_reader_and_pours_it = function()
    local disk = disk_of()
    local source = helper.at('outside/big.bin')

    helper.put(source, ('ab'):rep(100000))

    t.assert_equals({ disk:put('inside/big.bin', world.fs.reader(source)) }, { true })
    t.assert_equals(disk:get('inside/big.bin'), ('ab'):rep(100000))
    -- Читатель другого диска годится так же.
    t.assert_equals({ disk:put('copy.bin', disk:stream('inside/big.bin')) }, { true })
    t.assert_equals(disk:size('copy.bin'), 200000)
end

g.test_put_of_a_failing_reader_gives_its_failure_as_is = function()
    local disk = disk_of()
    local failure = { kind = 'broken' }
    local closed = false
    local reader = {
        read = function()
            return nil, failure
        end,
        close = function()
            closed = true
        end,
    }

    local ok, err = disk:put('a.txt', reader)

    t.assert_equals(ok, nil)
    t.assert_is(err, failure)
    t.assert_equals(closed, false)
    t.assert_equals(fio.listdir(world.root), {})
end

g.test_put_of_a_reader_closes_it_when_the_file_does_not_open = function()
    local disk = disk_of()
    local closed = false
    local reader = {
        read = function()
            return 'x'
        end,
        close = function()
            closed = true
        end,
    }

    with_fio({ open = refusing_open(errno.EACCES) })

    local ok, err = disk:put('a.txt', reader)

    t.assert_equals(ok, nil)
    helper.assert_failure(
        err,
        'denied',
        'диск local: файл a.txt не записан: ' .. errno.strerror(errno.EACCES)
    )
    t.assert_equals(closed, true)
end

g.test_denied_and_full_are_kinds_of_the_disk = function()
    local disk = disk_of()

    with_fio({ open = refusing_open(errno.EACCES) })

    local _, denied = disk:put('a.txt', 'x')

    helper.assert_failure(
        denied,
        'denied',
        'диск local: файл a.txt не записан: ' .. errno.strerror(errno.EACCES)
    )
    t.assert_equals(denied.cause.kind, 'denied')

    with_fio({ open = refusing_open(errno.ENOSPC) })

    local _, full = disk:writer('a.txt')

    helper.assert_failure(
        full,
        'full',
        'диск local: файл a.txt не записан: ' .. errno.strerror(errno.ENOSPC)
    )

    with_fio({ open = refusing_open(errno.EIO) })

    local _, failed = disk:put('a.txt', 'x')

    t.assert_equals(failed.kind, 'failed')
end

g.test_writer_failing_is_a_failure_of_the_disk = function()
    local disk = disk_of()

    with_fio({
        open = function()
            return {
                write = function()
                    return false, { errno = errno.ENOSPC }
                end,
                close = function()
                    return true
                end,
            }
        end,
    })

    local writer = disk:writer('a.txt')
    local ok, err = writer:write('x')

    t.assert_equals(ok, nil)
    helper.assert_failure(
        err,
        'full',
        'диск local: файл a.txt не записан: ' .. errno.strerror(errno.ENOSPC)
    )
    t.assert_equals(select(2, writer:finish()).kind, 'full')
end

g.test_directories_that_cannot_be_made_are_failures = function()
    local disk = disk_of()

    -- На месте каталога — файл: каталог под новым файлом не завести.
    helper.put(helper.at('a'), 'файл')

    local _, put_err = disk:put('a/b.txt', 'x')
    local _, writer_err = disk:writer('a/b.txt')

    helper.put(helper.at('c.txt'), 'x')

    local _, move_err = disk:move('c.txt', 'a/c.txt')

    for _, err in ipairs({ put_err, writer_err, move_err }) do
        t.assert_equals(err.kind, 'failed')
        t.assert_equals(err.cause.errno, errno.EEXIST)
    end

    t.assert_equals(helper.get(helper.at('c.txt')), 'x')
end

g.test_copy_pours_the_file_and_keeps_the_source = function()
    local disk = disk_of()

    helper.put(helper.at('a.txt'), 'данные')
    helper.put(helper.at('b/b.txt'), 'старое')

    t.assert_equals({ disk:copy('a.txt', 'b/b.txt') }, { true })
    t.assert_equals({ disk:copy('a.txt', 'c/d/e.txt') }, { true })
    t.assert_equals(
        { disk:get('a.txt'), disk:get('b/b.txt'), disk:get('c/d/e.txt') },
        { 'данные', 'данные', 'данные' }
    )
end

g.test_copy_closes_the_source_when_the_copy_does_not_open = function()
    local disk = disk_of()
    local closed = 0

    helper.put(helper.at('a.txt'), 'x')
    helper.put(helper.at('file'), 'x')
    with_fio({
        open = function(path, flags, mode)
            local handle = fio.open(path, flags, mode)

            return {
                read = function(_, size)
                    return handle:read(size)
                end,
                close = function()
                    closed = closed + 1

                    return handle:close()
                end,
            }
        end,
    })

    local ok, err = disk:copy('a.txt', 'file/b.txt')

    t.assert_equals(ok, nil)
    t.assert_equals(err.kind, 'failed')
    t.assert_equals(closed, 1)
end

g.test_copy_and_move_in_place_keep_the_file = function()
    local disk = disk_of()

    helper.put(helper.at('a.txt'), 'данные')

    t.assert_equals({ disk:copy('a.txt', 'a.txt') }, { true })
    t.assert_equals({ disk:move('a.txt', 'a.txt') }, { true })
    t.assert_equals(disk:get('a.txt'), 'данные')
    helper.assert_failure(
        select(2, disk:copy('b.txt', 'b.txt')),
        'missing',
        'диск local: файл b.txt не скопирован в b.txt: файла нет'
    )
end

g.test_move_renames_the_file = function()
    local disk = disk_of()

    helper.put(helper.at('a.txt'), 'данные')

    t.assert_equals({ disk:move('a.txt', 'архив/2026/a.txt') }, { true })
    t.assert_equals(disk:exists('a.txt'), false)
    t.assert_equals(disk:get('архив/2026/a.txt'), 'данные')
end

g.test_stat_that_fails_is_a_failure_everywhere = function()
    local disk = disk_of()

    with_fio({
        stat = function()
            return nil, { errno = errno.EACCES }
        end,
    })

    local reason = errno.strerror(errno.EACCES)

    helper.assert_failure(
        select(2, disk:exists('a.txt')),
        'denied',
        'диск local: файл a.txt не проверен: ' .. reason
    )
    helper.assert_failure(
        select(2, disk:delete('a.txt')),
        'denied',
        'диск local: файл a.txt не удалён: ' .. reason
    )
    helper.assert_failure(
        select(2, disk:get('a.txt')),
        'denied',
        'диск local: файл a.txt не прочитан: ' .. reason
    )
    helper.assert_failure(
        select(2, disk:size('a.txt')),
        'denied',
        'диск local: размер файла a.txt не узнан: ' .. reason
    )
    helper.assert_failure(
        select(2, disk:stream('a.txt')),
        'denied',
        'диск local: файл a.txt не прочитан: ' .. reason
    )
    helper.assert_failure(
        select(2, disk:copy('a.txt', 'b.txt')),
        'denied',
        'диск local: файл a.txt не скопирован в b.txt: ' .. reason
    )
    helper.assert_failure(
        select(2, disk:move('a.txt', 'b.txt')),
        'denied',
        'диск local: файл a.txt не перенесён в b.txt: ' .. reason
    )
end

g.test_temporary_link_is_the_signer_answer = function()
    local asked = {}
    local disk = disk_of({
        sign = function(path, expires)
            table.insert(asked, { path, expires })

            if path == 'нельзя' then
                return nil, { status = 404, message = 'маршрута нет' }
            end

            return '/files/' .. path .. '?signature=x'
        end,
    })

    t.assert_equals(disk:temporary_url('a b.txt', 60), '/files/a b.txt?signature=x')

    local url, err = disk:temporary_url('нельзя', 60)

    t.assert_equals(url, nil)
    helper.assert_failure(
        err,
        'failed',
        'диск local: ссылка на файл нельзя не подписана: маршрута нет'
    )
    t.assert_equals(asked, { { 'a b.txt', 60 }, { 'нельзя', 60 } })

    disk = disk_of({
        sign = function()
            return nil, 'подписи нет'
        end,
    })

    helper.assert_failure(
        select(2, disk:temporary_url('a', 1)),
        'failed',
        'диск local: ссылка на файл a не подписана: подписи нет'
    )
end
