--- Диск на драйвере s3: договор диска поверх настоящего клиента `tnt-s3`
--- на двойнике libcurl.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local web = helper.web

local g, world = helper.group('tnt.files.s3')

--- Ведро двойника на узле.
local BUCKET = 'http://127.0.0.1:9000/tnt-live'

--- Нет ключа.
local function no_key()
    return helper.fault(404, 'NoSuchKey', 'The specified key does not exist.')
end

--- Нет прав.
local function denied()
    return helper.fault(403, 'AccessDenied', 'Access Denied.')
end

--- Диск над клиентом на двойнике с приставкой `uploads/`.
---@param script table[] Ответы сервера по порядку
---@param extra table|nil Настройки диска поверх клиента и приставки
---@return any disk
---@return table sent
local function disk_of(script, extra)
    local client, sent = helper.client(script)
    local disk = world.files
        .new({
            disks = {
                uploads = helper.web.merged({ driver = 's3', client = client, prefix = 'uploads/' }, extra),
            },
        })
        :disk()

    return disk, sent
end

g.test_put_and_get_go_under_the_prefix = function()
    local disk, sent = disk_of({
        web.answer(200, { headers = { ETag = '"e"' } }),
        web.answer(200, { body = 'картинка' }),
    })

    t.assert_equals({ disk:put('avatars/7.png', 'картинка', { type = 'image/png' }) }, { true })
    t.assert_equals(disk:get('avatars/7.png'), 'картинка')
    t.assert_equals({ sent[1].method, sent[1].url }, { 'PUT', BUCKET .. '/uploads/avatars/7.png' })
    t.assert_equals(sent[1].options.headers['content-type'], 'image/png')
    t.assert_equals(sent[2].url, BUCKET .. '/uploads/avatars/7.png')
    t.assert_equals(disk.driver, 's3')
end

g.test_put_without_a_type_is_bytes = function()
    local disk, sent = disk_of({ web.answer(200) })

    t.assert_equals({ disk:put('a', 'x') }, { true })
    t.assert_equals(sent[1].options.headers['content-type'], 'application/octet-stream')
end

g.test_missing_object_is_missing_everywhere = function()
    local disk = disk_of({
        no_key(),
        web.answer(404),
        no_key(),
        web.answer(404),
        no_key(),
        no_key(),
    })
    local calls = {
        {
            function()
                return disk:get('нет.txt')
            end,
            'диск uploads: файл нет.txt не прочитан: файла нет',
        },
        {
            function()
                return disk:stream('нет.txt')
            end,
            'диск uploads: файл нет.txt не прочитан: файла нет',
        },
        {
            function()
                return disk:size('нет.txt')
            end,
            'диск uploads: размер файла нет.txt не узнан: файла нет',
        },
        {
            function()
                return disk:copy('нет.txt', 'b.txt')
            end,
            'диск uploads: файл нет.txt не скопирован в b.txt: '
                .. 'PUT 127.0.0.1:9000/tnt-live/uploads/b.txt: 404 NoSuchKey: The specified key does not exist.',
        },
        {
            function()
                return disk:move('нет.txt', 'b.txt')
            end,
            'диск uploads: файл нет.txt не перенесён в b.txt: '
                .. 'PUT 127.0.0.1:9000/tnt-live/uploads/b.txt: 404 NoSuchKey: The specified key does not exist.',
        },
    }

    for _, call in ipairs(calls) do
        local value, err = call[1]()

        t.assert_equals(value, nil)
        helper.assert_failure(err, 'missing', call[2])
    end
end

g.test_exists_and_size_ask_the_head = function()
    local disk, sent = disk_of({
        web.answer(200, { headers = { ['Content-Length'] = '42' } }),
        web.answer(404),
        web.answer(200, { headers = { ['Content-Length'] = '42' } }),
    })

    t.assert_equals(disk:exists('a'), true)
    t.assert_equals(disk:exists('b'), false)
    t.assert_equals(disk:size('a'), 42)
    t.assert_equals({ sent[1].method, sent[1].url }, { 'HEAD', BUCKET .. '/uploads/a' })
end

g.test_refusals_become_kinds_of_the_disk = function()
    local disk = disk_of({
        denied(),
        denied(),
        helper.fault(503, 'SlowDown', 'Reduce your request rate.'),
        helper.fault(400, 'InvalidArgument', 'Invalid Argument'),
        denied(),
        denied(),
        denied(),
    })
    local reason = 'HEAD 127.0.0.1:9000/tnt-live/uploads/a: 403 AccessDenied: Access Denied.'

    helper.assert_failure(
        select(2, disk:exists('a')),
        'denied',
        'диск uploads: файл a не проверен: ' .. reason
    )
    helper.assert_failure(
        select(2, disk:size('a')),
        'denied',
        'диск uploads: размер файла a не узнан: ' .. reason
    )
    t.assert_equals(select(2, disk:get('a')).kind, 'unavailable')
    t.assert_equals(select(2, disk:put('a', 'x')).kind, 'failed')
    t.assert_equals(select(2, disk:delete('a')).kind, 'denied')
    t.assert_equals(select(2, disk:copy('a', 'b')).kind, 'denied')
    t.assert_equals(select(2, disk:stream('a')).kind, 'denied')
end

g.test_timeout_broken_and_closed_are_unavailable = function()
    local disk, _ = disk_of({ web.no_answer('Timeout was reached'), web.no_answer('Could not connect to server') })

    t.assert_equals(select(2, disk:get('a')).kind, 'unavailable')
    t.assert_equals(select(2, disk:get('a')).kind, 'unavailable')

    local closed = disk_of({})

    closed.backend.client:close()

    local _, err = closed:get('a')

    t.assert_equals(err.kind, 'unavailable')
    t.assert_equals(err.cause.kind, 'closed')
end

g.test_delete_is_success_whether_there_was_an_object_or_not = function()
    local disk, sent = disk_of({ web.answer(204) })

    t.assert_equals(disk:delete('a'), true)
    t.assert_equals({ sent[1].method, sent[1].url }, { 'DELETE', BUCKET .. '/uploads/a' })
end

g.test_copy_and_move_are_done_by_the_service = function()
    local copied = web.answer(200, { body = '<CopyObjectResult><ETag>"e"</ETag></CopyObjectResult>' })
    local disk, sent = disk_of({ copied, copied, web.answer(204) })

    t.assert_equals({ disk:copy('a', 'b/c') }, { true })
    t.assert_equals({ sent[1].method, sent[1].url }, { 'PUT', BUCKET .. '/uploads/b/c' })
    t.assert_equals(sent[1].options.headers['x-amz-copy-source'], '/tnt-live/uploads/a')

    t.assert_equals({ disk:move('a', 'd') }, { true })
    t.assert_equals({ sent[2].method, sent[3].method, sent[3].url }, { 'PUT', 'DELETE', BUCKET .. '/uploads/a' })
end

g.test_copy_and_move_in_place_only_ask_whether_the_file_is_there = function()
    local disk, sent = disk_of({
        web.answer(200, { headers = { ['Content-Length'] = '1' } }),
        web.answer(200, { headers = { ['Content-Length'] = '1' } }),
        web.answer(404),
        denied(),
    })

    t.assert_equals({ disk:copy('a', 'a') }, { true })
    t.assert_equals({ disk:move('a', 'a') }, { true })
    helper.assert_failure(
        select(2, disk:move('b', 'b')),
        'missing',
        'диск uploads: файл b не перенесён в b: файла нет'
    )
    t.assert_equals(select(2, disk:copy('c', 'c')).kind, 'denied')

    -- Службе ушли только вопросы: ни копии на себя, ни удаления.
    for _, request in ipairs(sent) do
        t.assert_equals(request.method, 'HEAD')
    end

    t.assert_equals(#sent, 4)
end

g.test_move_that_fails_to_delete_is_a_failure = function()
    local copied = web.answer(200, { body = '<CopyObjectResult><ETag>"e"</ETag></CopyObjectResult>' })
    local disk = disk_of({ copied, denied() })
    local ok, err = disk:move('a', 'b')

    t.assert_equals({ ok, err.kind }, { nil, 'denied' })
end

g.test_stream_reads_the_object_by_ranges = function()
    local disk, sent = disk_of({
        web.answer(200, { headers = { ['Content-Length'] = '3', ETag = '"e"' } }),
        web.answer(206, { body = 'abc' }),
    })
    local reader = disk:stream('a')
    local chunks, err = helper.drain(reader)

    t.assert_equals({ chunks, err }, { { 'abc' }, nil })
    t.assert_equals(sent[2].options.headers.range, 'bytes=0-2')
end

g.test_stream_replaced_midway_is_a_failure_of_the_disk = function()
    local disk = disk_of({
        web.answer(200, { headers = { ['Content-Length'] = '3', ETag = '"e"' } }),
        helper.fault(412, 'PreconditionFailed', 'At least one of the pre-conditions you specified did not hold'),
    })
    local chunk, err = disk:stream('a'):read()

    t.assert_equals(chunk, nil)
    t.assert_equals({ err.kind, err.cause.kind }, { 'failed', 'conflict' })
end

g.test_writer_puts_the_object_on_finish = function()
    local disk, sent = disk_of({ web.answer(200) })
    local writer = disk:writer('a.csv', { type = 'text/csv' })

    writer:write('a;b\n')
    writer:write('1;2\n')

    t.assert_equals({ writer:finish() }, { true })
    t.assert_equals({ sent[1].method, sent[1].body }, { 'PUT', 'a;b\n1;2\n' })
    t.assert_equals(sent[1].options.headers['content-type'], 'text/csv')
end

g.test_writer_refused_on_finish_is_a_failure_of_the_disk = function()
    local disk = disk_of({ denied() })
    local writer = disk:writer('a')
    local ok, err = writer:finish()

    t.assert_equals({ ok, err.kind }, { nil, 'denied' })
end

g.test_writer_abort_refused_is_a_failure = function()
    local initiated = web.answer(200, { body = '<InitiateMultipartUploadResult><UploadId>U</UploadId>' })
    local disk = disk_of({ initiated, web.answer(200, { headers = { ETag = '"p"' } }), denied() })
    local writer = disk:writer('a')

    writer:write(('x'):rep(world.s3.PART_SIZE))

    local ok, err = writer:abort()

    t.assert_equals({ ok, err.kind }, { nil, 'denied' })
end

g.test_temporary_link_is_signed_by_the_bucket = function()
    local disk, sent = disk_of({})
    local url = disk:temporary_url('a b.txt', 60)

    t.assert_equals(url:find(BUCKET .. '/uploads/a%20b.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&', 1, true), 1)
    t.assert_str_contains(url, '&X-Amz-Expires=60&')
    t.assert_equals(#sent, 0)
end

g.test_url_is_the_address_of_the_disk = function()
    local disk = disk_of({}, { url = 'https://cdn.example.org/uploads' })

    t.assert_equals(disk:url('a b.png'), 'https://cdn.example.org/uploads/a%20b.png')
end

g.test_without_a_prefix_the_path_is_the_key = function()
    local client, sent = helper.client({ web.answer(200, { body = 'x' }) })
    local disk = world.files.new({ disks = { root = { driver = 's3', client = client } } }):disk()

    t.assert_equals(disk:get('a/b'), 'x')
    t.assert_equals(sent[1].url, BUCKET .. '/a/b')
end
