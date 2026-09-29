rockspec_format = '3.0'

package = 'tnt-files'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-files.git',
    branch = 'main',
}

description = {
    summary = 'Файлы приложения: диски со сменными драйверами local и s3 за одним договором',
    detailed = [[
        Диск по имени — store:disk('uploads') — и один договор на любом
        драйвере: put строкой либо читателем кусками, get, stream кусками,
        writer, exists, delete, copy, move, size, публичный адрес url
        и ссылка со сроком temporary_url. Место файла выбирает настройка,
        а прикладной код одинаков: переезд с каталога узла на ведро
        не трогает ни одного места, где решают по отказу.

        Драйвер local кладёт файлы в каталог узла: запись атомарна и со
        сбросом на диск, каталоги под файлом заводятся сами, копия идёт
        кусками, перенос — переименованием. Ссылку со сроком на файл узла
        подписывает функция sign из настроек — тот, кто файл раздаёт.

        Драйвер s3 кладёт объекты в ведро через клиент S3, пришедший
        настройкой client: одно ведро служит многим дискам со своими
        приставками ключей, копия и перенос идут силами службы, чтение —
        запросами с диапазоном, запись — загрузкой частями. В памяти узла
        лежит один кусок, сколько бы ни весил файл.

        Отказ — пара nil, err с родом, одним на все драйверы: missing,
        denied, full, unavailable, failed; отказ драйвера как есть лежит
        в err.cause. Негодная настройка, незнакомый диск и негодный путь —
        исключение на строке того, кто позвал.

        Зависит от tnt-must (проверки настроек, путей и аргументов)
        и tnt-fs (драйвер local и договор чтения и записи кусками).
        Покрытие строк и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-files',
    issues_url = 'https://github.com/tnt-skein/tnt-files/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'files', 'storage', 's3', 'filesystem' },
}

dependencies = {
    'lua >= 5.1',
    -- Проверки настроек, путей и аргументов на строке вызывающего.
    'tnt-must',
    -- Драйвер local и договор читателя и писателя кусками (fs.pipe).
    'tnt-fs',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.files'] = 'tnt/files.lua',
        ['tnt.files.disk'] = 'tnt/files/disk.lua',
        ['tnt.files.driver.local'] = 'tnt/files/driver/local.lua',
        ['tnt.files.driver.s3'] = 'tnt/files/driver/s3.lua',
        ['tnt.files.failure'] = 'tnt/files/failure.lua',
        ['tnt.files.reader'] = 'tnt/files/reader.lua',
        ['tnt.files.settings'] = 'tnt/files/settings.lua',
        ['tnt.files.writer'] = 'tnt/files/writer.lua',
    },
}
