# systemd262 — статический PID 1 в Docker

Ubuntu 24.04, в которой PID 1 — полностью статический `systemd` 262.
Собран по рецепту из NEWS v262:

```
--default-library=static --prefer-static -Dbuild-static=true -Dsystemd-multicall-binary=true
```

Пакета systemd в образе нет. Файлов юнитов тоже нет: v262 несёт базовые
таргеты внутри PID 1. Кроме него в образ положены `systemd-shutdown`,
`systemctl` и `systemd-run` (варианты `.standalone`, из динамических
зависимостей у них только glibc).

## Запуск

```
docker run -d -t --name s262 --cgroupns=private \
  --security-opt writable-cgroups=true \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
  <dockerhub-user>/systemd262

docker exec s262 systemctl is-system-running   # running
docker stop s262                                # штатный halt, exit 0
```

- `writable-cgroups=true` даёт PID 1 писать в cgroupfs без `--privileged`.
- `-t` создаёт `/dev/console`: только туда PID 1 пишет лог, и оттуда он
  попадает в `docker logs`.
- Свои юниты монтируются в `/etc/systemd/system`.

## Сценарии

```
./scenarios/run.sh             # собрать образ и прогнать
NO_BUILD=1 ./scenarios/run.sh  # на уже собранном образе
```

Проверяются: загрузка на встроенных юнитах, `Restart=` с
`RestartRandomizedDelaySec=`, `User=` без NSS, таймер, сокет-активация,
`systemd-run` с `MemoryMax=`, `ActivatingConcurrencyMax=` и остановка через
`docker stop`.

## Ограничения (XFAIL в сценариях)

Песочница на mount-namespace не работает:

- без `CAP_SYS_ADMIN` systemd молча пропускает `PrivateTmp=`/`ProtectSystem=`,
  а `DynamicUser=` отказывается стартовать;
- с `CAP_SYS_ADMIN` монтаж падает с `EOPNOTSUPP`: libmount в v262
  подгружается через `dlopen()`, а в static-сборке он отключён.

По той же причине `+BLKID`, `+SELINUX` в `systemd --version` означают
«скомпилировано», но не «доступно во время работы».

`systemd-run --wait/--pty` требуют dbus-daemon, которого в образе нет.
Без этих флагов `systemd-run` говорит с PID 1 напрямую через
`/run/systemd/private`.
