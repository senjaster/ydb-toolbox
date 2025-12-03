# YDB Interactive Shell

Интерактивная оболочка для удобной работы с YDB, которая избавляет от необходимости каждый раз указывать параметры аутентификации и подключения.

## Зачем это нужно?

При работе с YDB напрямую приходится каждый раз указывать множество параметров:

```bash
# Без скрипта - длинные команды с повторяющимися параметрами
/opt/ydb/bin/ydb -e grpcs://ydb-node-1:2135 -d /my-cluster --ca-file /opt/ydb/certs/ca.crt --user root auth get-token --force > /tmp/token
/opt/ydb/bin/ydb-dstool -e grpcs://ydb-node-1:2135 --ca-file /opt/ydb/certs/ca.crt --token-file /tmp/token pdisk list
/opt/ydb/bin/ydbd -s grpcs://ydb-node-1:2135 --ca-file /opt/ydb/certs/ca.crt -f /tmp/token admin database /test/db create ssd:32
```

**YDB Shell** позволяет один раз авторизоваться и затем вызывать команды без указания всех параметров подключения каждый раз.

## Примеры использования

### 1. Локальный запуск на узле

```bash
# Запускаем интерактивную оболочку
./ydb-shell.sh -d /my-cluster

# Теперь доступны короткие команды
ydb-dstool pdisk list
ydbd admin database /test/mydb create ssd:32

# Выход из оболочки
exit
```

По умолчанию используются следующие параметры подключения:
- `YDB_ENDPOINT=grpcs://$(hostname):2135`
- `YDB_DATABASE=/Root`
- `YDB_CA_FILE=/opt/ydb/certs/ca.crt`
- `YDB_USER=root`

### 2. Удаленный запуск через SSH

YDB Shell умеет подключаться к узлу кластера по ssh и выполняться на нем. Для этого нужно указать ключ --ssh, например так:

```bash 
# На рабочей станции (не на узле ydb) выполняем следующие команды:
# Устанавливаем локальные переменные окружения
export YDB_DATABASE=/cluster/production
export YDB_USER=admin

# Подключаемся к удаленному хосту.
# Переменные окружения передаются автоматически
./ydb-shell.sh --ssh user@ydb-node-1.ydb-cluster.com

# Теперь мы находимся в ssh-сессии на удаленном узле
ydb admin cluster config fetch > dynconfig.yaml
# Поскольку это обычный shell, можно использовать любые команды:
vim dynconfig.yaml
ydb admin cluster config replace -f dynconfig.yaml

# Выход - отключаемся от ssh
exit
```

Скрипт автоматически:
1. Загружает себя на удаленный хост через `scp`
2. Передает все переменные окружения `YDB_*`
3. Запускает интерактивную оболочку на удаленном сервере
4. Удаляет временные файлы после завершения

### 3. Удаленный запуск с кастомными параметрами

Запуск с явным указанием базы данных и CA-файла:

```bash
# На рабочей станции (не на узле ydb) выполняем следующую команду:
./ydb-shell.sh --ssh user@ydb-server.example.com \
  -d /cluster/custom_database \
  --ca-file ./ca.crt \
  -v

# Важно: файл ca.crt уже должен находиться в домашней папке на  удаленном сервере

# Теперь мы находимся в ssh-сессии на удаленном узле
ydb scheme ls /cluster/custom_database
ydb sql -s "SELECT version()"

# Выход - отключаемся от ssh
exit
```

## Справка

Для просмотра всех доступных параметров запустите

```bash
./ydb-shell.sh --help
```
