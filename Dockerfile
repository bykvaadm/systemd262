# syntax=docker/dockerfile:1
#
# Ubuntu + статический PID 1 из systemd 262. Пакета systemd в финальном
# образе нет: только бинарники из сборки.
#
# Рецепт сборки взят из NEWS v262: --default-library=static --prefer-static
# -Dbuild-static=true -Dsystemd-multicall-binary=true даёт один полностью
# статический файл «PID 1 + systemd-executor». NSS и dlopen() в нём нет,
# пользователи ищутся упрощённо, прямо в /etc/passwd и /etc/group.
#
# Файлов юнитов в образе нет. Начиная с v262 PID 1 несёт встроенные базовые
# юниты (basic.target, multi-user.target, shutdown.target…), поэтому система
# загружается и без них. Свои юниты кладутся в /etc/systemd/system.
#
# Рядом лежит systemd-shutdown: на выключении PID 1 execve'ит его.
# Без него срабатывает fallback: reboot() в контейнере даёт EPERM,
# и `docker stop` заканчивается кодом 255 вместо 0.
#
# Для управления добавлены systemctl и systemd-run. Как и systemd-shutdown,
# это варианты .standalone: libsystemd-shared вшита статически, динамически
# подгружается только glibc, которая в ubuntu:24.04 уже есть. С PID 1 они общаются через
# /run/systemd/private, dbus-daemon не нужен.
#
# Запуск. writable-cgroups даёт писать в cgroupfs без --privileged.
# -t создаёт /dev/console, иначе лог PID 1 не попадёт в `docker logs`:
#   docker run -d -t --name s262 --cgroupns=private \
#     --security-opt writable-cgroups=true \
#     --tmpfs /run --tmpfs /run/lock --tmpfs /tmp systemd262:static

FROM ubuntu:24.04 AS builder

ARG SYSTEMD_TAG=v262
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git gcc pkg-config \
        meson ninja-build gperf python3-jinja2 \
        libcap-dev libblkid-dev libmount-dev libselinux1-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN git clone --depth 1 --branch "${SYSTEMD_TAG}" \
        https://github.com/systemd/systemd.git src

RUN cd src && meson setup build \
        --default-library=static --prefer-static \
        -Dbuild-static=true \
        -Dsystemd-multicall-binary=true \
        -Dmode=release \
    && ninja -C build systemd systemd-shutdown.standalone \
        systemctl.standalone systemd-run.standalone \
    && strip --strip-all build/systemd build/systemd-shutdown.standalone \
        build/systemctl.standalone build/systemd-run.standalone

FROM ubuntu:24.04

COPY --from=builder /build/src/build/systemd /usr/lib/systemd/systemd
COPY --from=builder /build/src/build/systemd-shutdown.standalone /usr/lib/systemd/systemd-shutdown
COPY --from=builder /build/src/build/systemctl.standalone /usr/bin/systemctl
COPY --from=builder /build/src/build/systemd-run.standalone /usr/bin/systemd-run
RUN ln -sf /usr/lib/systemd/systemd /sbin/init

# journald в образе нет. Лог PID 1 идёт на /dev/console, то есть в `docker logs`.
ENV SYSTEMD_LOG_TARGET=console

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/sbin/init"]
