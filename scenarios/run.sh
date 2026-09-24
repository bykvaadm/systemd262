#!/usr/bin/env bash
# Прогон сценариев против образа со статическим systemd 262.
#
#   ./scenarios/run.sh            # собрать образ и прогнать
#   NO_BUILD=1 ./scenarios/run.sh # взять уже собранный образ
#
# Каждый сценарий печатает PASS/FAIL. Отдельно помечены ожидаемые
# ограничения статической сборки (XFAIL): они ломаются так, как и должны.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
image=${IMAGE:-systemd262:static}
name=s262-scenarios
pass=0 fail=0 xfail=0

ok()    { echo "  PASS  $*"; pass=$((pass+1)); }
bad()   { echo "  FAIL  $*"; fail=$((fail+1)); }
xf()    { echo "  XFAIL $*"; xfail=$((xfail+1)); }
x()     { docker exec "$name" "$@"; }
prop()  { x systemctl show -P "$2" "$1"; }
logs()  { docker logs "$name" 2>&1 | sed 's/\x1b\[[0-9;:?]*[a-zA-Z]//g; s/\x1b\][^\\]*\\//g'; }

if [[ -z ${NO_BUILD:-} ]]; then
    docker build -q -t "$image" "$here/.." >/dev/null || { echo "build failed"; exit 1; }
fi
docker rm -f "$name" >/dev/null 2>&1

# -t нужен ради /dev/console: только туда PID 1 пишет лог, и оттуда он
# попадает в `docker logs`.
docker run -d -t --name "$name" \
    --cgroupns=private --security-opt writable-cgroups=true \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
    -v "$here/units:/etc/systemd/system:ro" \
    "$image" >/dev/null || { echo "docker run failed"; exit 1; }
trap 'docker rm -f "$name" >/dev/null 2>&1' EXIT

echo "== 1. Загрузка"
for _ in $(seq 20); do
    st=$(x systemctl is-system-running 2>/dev/null)
    [[ $st == running || $st == degraded ]] && break
    sleep 0.5
done
[[ $st == running ]] && ok "is-system-running = running" || bad "is-system-running = $st"
x sh -c 'ldd /usr/lib/systemd/systemd 2>&1 || true' | grep -q "not a dynamic" \
    && ok "PID 1 статический (ldd: not a dynamic executable)" || bad "PID 1 динамический"
[[ $(x cat /proc/1/comm) == systemd ]] && ok "PID 1 = systemd" || bad "PID 1 не systemd"
fin=$(logs | grep -o 'Startup finished in .*')
[[ -n $fin ]] && ok "$fin" || bad "нет 'Startup finished'"
x sh -c '! ls /usr/lib/systemd/system/*.target >/dev/null 2>&1' \
    && [[ $(prop multi-user.target ActiveState) == active ]] \
    && ok "multi-user.target активен без файлов юнитов на диске (встроенные юниты)" \
    || bad "встроенные юниты"

echo "== 2. Restart= + RestartRandomizedDelaySec="
x systemctl start demo-crash.service
sleep 4
n=$(prop demo-crash.service NRestarts)
x systemctl stop demo-crash.service
(( n >= 2 )) && ok "demo-crash перезапущен $n раз за 4с" || bad "NRestarts=$n"
[[ $(prop demo-crash.service RestartRandomizedDelayUSec) == 500ms ]] \
    && ok "RestartRandomizedDelaySec распознан" || bad "RestartRandomizedDelaySec не распознан"

echo "== 3. User= без NSS"
x systemctl start demo-nobody.service
[[ $(x cat /tmp/demo-nobody.out 2>/dev/null) == nobody ]] \
    && ok "сервис выполнился от nobody" || bad "User=nobody не сработал"

echo "== 4. Таймер"
x systemctl start demo-tick.timer
sleep 6.5
t=$(x sh -c 'wc -l < /run/demo-ticks' 2>/dev/null || echo 0)
x systemctl stop demo-tick.timer
(( t >= 3 )) && ok "таймер сработал $t раз за 6.5с" || bad "таймер сработал $t раз"

echo "== 5. Сокет-активация (Accept=yes)"
x systemctl start demo-echo.socket
reply=$(x bash -c 'exec 3<>/dev/tcp/127.0.0.1/7777; echo ping >&3; read -t 3 l <&3; echo "$l"')
[[ $reply == "echo: ping" ]] && ok "ответ: '$reply'" || bad "ответ: '$reply'"
[[ $(prop demo-echo.socket NAccepted) -ge 1 ]] && ok "NAccepted=$(prop demo-echo.socket NAccepted)" || bad "NAccepted=0"

echo "== 6. Transient-юнит с лимитом памяти (systemd-run)"
x systemd-run -q --unit=demo-mem -p MemoryMax=64M sleep 300
mm=$(x cat /sys/fs/cgroup/system.slice/demo-mem.service/memory.max 2>/dev/null)
[[ $mm == 67108864 ]] && ok "memory.max = $mm" || bad "memory.max = '$mm'"
x systemctl stop demo-mem.service

echo "== 7. ActivatingConcurrencyMax= (новое в v262)"
x systemctl start --no-block demo-q@a.service demo-q@b.service demo-q@c.service
sleep 7.5
starts=$(x sh -c 'sort -k2 -n /run/demo-q | awk "{print \$2}"' 2>/dev/null)
gaps=$(awk 'NR>1{printf "%.1f ", $1-p} {p=$1}' <<<"$starts")
min=$(awk 'NR>1{d=$1-p; if(m==""||d<m)m=d} {p=$1} END{print m+0}' <<<"$starts")
if [[ $(wc -l <<<"$starts") -eq 3 ]] && awk "BEGIN{exit !($min >= 1.9)}"; then
    ok "3 задания шли по одному, интервалы: ${gaps}с"
else
    bad "стартов: $(wc -l <<<"$starts"), интервалы: ${gaps}"
fi

echo "== 8. Песочница: обычный запуск, без CAP_SYS_ADMIN"
# unshare(CLONE_NEWNS) запрещён, поэтому systemd молча запускает сервис
# без песочницы. DynamicUser= так не умеет и отказывается стартовать.
x systemctl start demo-private.service 2>/dev/null
if [[ $(prop demo-private.service Result) == success ]] && x test -e /tmp/demo-private; then
    xf "PrivateTmp: сервис стартовал, но /tmp общий (песочница молча пропущена)"
elif [[ $(prop demo-private.service Result) == success ]]; then
    ok "PrivateTmp: /tmp изолирован"
else
    bad "PrivateTmp: Result=$(prop demo-private.service Result)"
fi
x systemd-run -q --unit=demo-dyn -p Type=oneshot -p DynamicUser=yes /bin/true 2>/dev/null
if logs | grep -q 'demo-dyn.service: Failed to set up mount namespacing'; then
    xf "DynamicUser: отказ на шаге NAMESPACE"
elif [[ $(prop demo-dyn.service Result) == success ]]; then
    ok "DynamicUser работает"
else
    bad "DynamicUser: Result=$(prop demo-dyn.service Result)"
fi

echo "== 9. Остановка (docker stop → SIGRTMIN+3)"
t0=$(date +%s.%N)
docker stop -t 20 "$name" >/dev/null
dt=$(awk "BEGIN{printf \"%.1f\", $(date +%s.%N)-$t0}")
code=$(docker inspect -f '{{.State.ExitCode}}' "$name")
if awk "BEGIN{exit !($dt < 10)}" && [[ $code == 0 ]] && logs | grep -q 'Exiting container'; then
    ok "штатное завершение за ${dt}с через systemd-shutdown, exit code $code"
else
    bad "остановка за ${dt}с, exit code $code"
fi

echo "== 10. Песочница с CAP_SYS_ADMIN: предел статической сборки"
# unshare теперь разрешён, но сам монтаж идёт через libmount, а её
# static-сборка загрузить не может (dlopen отключён).
docker rm -f "$name" >/dev/null
docker run -d -t --name "$name" \
    --cgroupns=private --security-opt writable-cgroups=true \
    --cap-add SYS_ADMIN --security-opt apparmor=unconfined \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
    -v "$here/units:/etc/systemd/system:ro" \
    "$image" >/dev/null
for _ in $(seq 20); do [[ $(x systemctl is-system-running 2>/dev/null) == running ]] && break; sleep 0.5; done
x systemctl start demo-private.service 2>/dev/null
# Причину (dlopen libmount) видно только при SYSTEMD_LOG_LEVEL=debug.
if logs | grep -q 'demo-private.service: Failed to set up mount namespacing: .*Operation not supported'; then
    xf "PrivateTmp падает: namespace есть, libmount нет (EOPNOTSUPP)"
elif [[ $(prop demo-private.service Result) == success ]] && ! x test -e /tmp/demo-private; then
    ok "PrivateTmp работает с SYS_ADMIN"
else
    bad "PrivateTmp с SYS_ADMIN: Result=$(prop demo-private.service Result)"
fi

echo
echo "итого: PASS=$pass FAIL=$fail XFAIL=$xfail"
(( fail == 0 ))
