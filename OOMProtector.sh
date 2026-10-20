#!/bin/bash

# Стили и цвета
BOLD='\033[1m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'
NC='\033[0m'

log()  { echo -e "${B_CYAN}[*]${NC} $1"; }
ok()   { echo -e "${B_GREEN}[+]${NC} $1"; }
warn() { echo -e "${B_YELLOW}[!]${NC} $1"; }
err()  { echo -e "${B_RED}[-]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    err "Запустите скрипт от имени root."
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    err "Не найден systemctl — скрипт работает только на системах с systemd."
    exit 1
fi

if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
    warn "Скрипт рассчитан на Ubuntu/Debian."
fi

DROPIN_BASE="/etc/systemd/system"
DROPIN_NAME="oom.conf"
MARKER="# Managed by OOMProtector"
DEFAULT_ADJ="-500"
DEFAULT_UNITS="x-ui caddy nginx fail2ban subpage-server"

unit_exists() { systemctl cat "${1}.service" &>/dev/null; }
dropin_dir()  { echo "${DROPIN_BASE}/${1}.service.d"; }
dropin_file() { echo "${DROPIN_BASE}/${1}.service.d/${DROPIN_NAME}"; }

# Юниты, для которых drop-in создан этим скриптом (по метке в первой строке)
get_managed_units() {
    local f u
    for f in "$DROPIN_BASE"/*.service.d/"$DROPIN_NAME"; do
        [ -f "$f" ] || continue
        grep -qF "$MARKER" "$f" 2>/dev/null || continue
        u="${f#"$DROPIN_BASE"/}"
        echo "${u%%.service.d/*}"
    done
}

# Записывает значение прямо в процессы службы, без перезапуска.
# Печатает число обновлённых процессов.
apply_live() {
    local unit="$1" adj="$2" n=0 pid cg procs=""
    cg=$(systemctl show -p ControlGroup --value "${unit}.service" 2>/dev/null)
    if [ -n "$cg" ] && [ -r "/sys/fs/cgroup${cg}/cgroup.procs" ]; then
        procs=$(cat "/sys/fs/cgroup${cg}/cgroup.procs")
    fi
    if [ -z "$procs" ]; then
        procs=$(systemctl show -p MainPID --value "${unit}.service" 2>/dev/null)
    fi
    for pid in $procs; do
        [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 0 ] && [ -w "/proc/${pid}/oom_score_adj" ] || continue
        echo "$adj" > "/proc/${pid}/oom_score_adj" 2>/dev/null && n=$((n + 1))
    done
    echo "$n"
}

uninstall_oomprotector() {
    echo -e "${B_CYAN}${BOLD}Удаление OOMProtector${NC}"
    echo

    local units u cfg n
    units=$(get_managed_units)
    if [ -z "$units" ]; then
        warn "Drop-in файлы OOMProtector не найдены — удалять нечего."
        return
    fi

    for u in $units; do
        rm -f "$(dropin_file "$u")"
        # Резервную копию удаляем только если она тоже наша, ручной oom.conf не трогаем
        if grep -qF "$MARKER" "$(dropin_file "$u").bak" 2>/dev/null; then
            rm -f "$(dropin_file "$u").bak"
        fi
        rmdir "$(dropin_dir "$u")" 2>/dev/null
        ok "Drop-in для ${u} удалён."
    done
    systemctl daemon-reload

    # Возвращаем работающим службам значение, которое теперь задаёт systemd
    for u in $units; do
        if systemctl is-active --quiet "${u}.service"; then
            cfg=$(systemctl show -p OOMScoreAdjust --value "${u}.service" 2>/dev/null)
            n=$(apply_live "$u" "${cfg:-0}")
            ok "Служба ${u}: значение в памяти возвращено к ${cfg:-0} (процессов: ${n})."
        fi
    done

    echo
    echo -e "${B_GREEN}${BOLD}OOMProtector полностью удалён.${NC}"
    warn "Службы не перезапускались — их конфигурация и данные не затронуты."
}

echo -e "${B_CYAN}${BOLD}OOMProtector${NC}"
echo
echo -e "1) Установить"
echo -e "2) Удалить"
read -p $'\033[1;33mВаш выбор [1-2]: \033[0m' ACTION_CHOICE

case "$ACTION_CHOICE" in
    2)
        uninstall_oomprotector
        exit 0
        ;;
    1) ;;
    *) err "Неверный выбор. Выход."; exit 1 ;;
esac
echo

echo -e "${BOLD}Конфигурация OOMProtector${NC}"
echo
echo -e "OOMProtector снижает вероятность того, что OOM-киллер ядра убьёт важные службы"
echo -e "(${BOLD}x-ui${NC}, ${BOLD}caddy${NC}, ${BOLD}nginx${NC}, ${BOLD}fail2ban${NC}, ${BOLD}subpage-server${NC}): для каждой найденной в системе"
echo -e "службы создаётся systemd drop-in с ${BOLD}OOMScoreAdjust${NC}. Новое значение сразу применяется"
echo -e "к работающим процессам через /proc — перезапуск не обязателен."
echo

# Обнаружение существующей установки: вытаскиваем текущие настройки
# из уже созданных drop-in файлов, если есть.
EXISTING_UNITS=$(get_managed_units | tr '\n' ' ' | sed 's/ $//')
EXISTING_ADJ=""

if [ -n "$EXISTING_UNITS" ]; then
    echo -e "${B_YELLOW}Обнаружена существующая установка OOMProtector.${NC}"
    EXISTING_ADJ=$(grep -oP '(?<=^OOMScoreAdjust=)-?[0-9]+' "$(dropin_file "${EXISTING_UNITS%% *}")" 2>/dev/null | head -1)
    echo -e "  Защищённые службы:     $EXISTING_UNITS"
    [ -n "$EXISTING_ADJ" ] && echo -e "  Текущее значение:      $EXISTING_ADJ"
    echo -e "${B_YELLOW}При переустановке можно оставить значения без изменений (Enter) или задать новые.${NC}"
    echo
fi

# Список служб: стандартные + уже защищённые + указанные вручную
UNITS=""
echo -e "${B_CYAN}Поиск служб в системе:${NC}"
for u in $DEFAULT_UNITS $EXISTING_UNITS; do
    case " $UNITS " in *" $u "*) continue ;; esac
    if unit_exists "$u"; then
        if systemctl is-active --quiet "${u}.service"; then
            ok "${u} — найдена, запущена"
        else
            ok "${u} — найдена, не запущена"
        fi
        UNITS="$UNITS $u"
    else
        warn "${u} — не найдена, пропускаю"
    fi
done
echo

read -p $'\033[1;33mДополнительные службы через пробел (Enter — пропустить): \033[0m' EXTRA_INPUT
for u in $EXTRA_INPUT; do
    u="${u%.service}"
    case " $UNITS " in *" $u "*) continue ;; esac
    if unit_exists "$u"; then
        ok "${u} — добавлена"
        UNITS="$UNITS $u"
    else
        warn "${u} — не найдена, пропускаю"
    fi
done
UNITS=$(echo "$UNITS" | sed 's/^ *//')

if [ -z "$UNITS" ]; then
    err "Не найдено ни одной службы для защиты. Выход."
    exit 1
fi

echo
echo -e "${B_CYAN}Укажите значение OOMScoreAdjust (от -1000 до 1000):${NC}"
echo -e "  - чем меньше значение, тем реже службу выбирает OOM-киллер"
echo -e "  - -1000 полностью исключает службу из выбора"
if [ -n "$EXISTING_ADJ" ]; then
    read -p $'\033[1;33m'"Значение (Enter — оставить текущее: $EXISTING_ADJ): "$'\033[0m' ADJ
    ADJ="${ADJ:-$EXISTING_ADJ}"
else
    read -p $'\033[1;33m'"Значение [по умолчанию $DEFAULT_ADJ]: "$'\033[0m' ADJ
    ADJ="${ADJ:-$DEFAULT_ADJ}"
fi

if ! [[ "$ADJ" =~ ^-?[0-9]+$ ]] || [ "$ADJ" -lt -1000 ] || [ "$ADJ" -gt 1000 ]; then
    err "Значение должно быть целым числом от -1000 до 1000. Выход."
    exit 1
fi

echo
echo -e "${B_CYAN}Как применить значение к работающим службам?${NC}"
echo -e "1) На лету — без перезапуска (рекомендуется, не рвёт соединения клиентов)"
echo -e "2) Перезапустить службы"
read -p $'\033[1;33mВаш выбор [1-2]: \033[0m' APPLY_CHOICE

case "$APPLY_CHOICE" in
    1|2) ;;
    *) err "Неверный выбор. Выход."; exit 1 ;;
esac
echo

# systemd-oomd убивает службы по давлению памяти и игнорирует OOMScoreAdjust,
# ему нужна отдельная отметка.
OOMD_ACTIVE=0
if systemctl is-active --quiet systemd-oomd 2>/dev/null; then
    OOMD_ACTIVE=1
    warn "Обнаружен systemd-oomd — добавляю ManagedOOMPreference=omit."
fi

NEW_CONTENT="${MARKER}
[Service]
OOMScoreAdjust=${ADJ}"
[ "$OOMD_ACTIVE" -eq 1 ] && NEW_CONTENT="${NEW_CONTENT}
ManagedOOMPreference=omit"

log "Создание drop-in файлов..."
for u in $UNITS; do
    file=$(dropin_file "$u")
    if [ -f "$file" ] && [ "$(cat "$file")" == "$NEW_CONTENT" ]; then
        ok "${u}: drop-in уже настроен."
        continue
    fi
    mkdir -p "$(dropin_dir "$u")"
    if [ -f "$file" ]; then
        if ! grep -qF "$MARKER" "$file"; then
            warn "${u}: найден oom.conf, созданный вручную — сохранён как ${file}.bak"
        fi
        # Ручной бэкап не затираем: перезаписываем .bak только если он наш или его нет
        if [ ! -f "${file}.bak" ] || grep -qF "$MARKER" "${file}.bak" 2>/dev/null; then
            cp -f "$file" "${file}.bak"
        fi
    fi
    echo "$NEW_CONTENT" > "$file"
    chmod 644 "$file"
    ok "${u}: записан ${file}"
done

systemctl daemon-reload
ok "Конфигурация systemd перечитана."
echo

for u in $UNITS; do
    if ! systemctl is-active --quiet "${u}.service"; then
        warn "${u}: служба не запущена — значение вступит в силу при её старте."
        continue
    fi
    if [ "$APPLY_CHOICE" = "2" ]; then
        if systemctl restart "${u}.service"; then
            ok "${u}: служба перезапущена."
        else
            err "${u}: не удалось перезапустить службу."
        fi
    else
        n=$(apply_live "$u" "$ADJ")
        if [ "$n" -gt 0 ]; then
            ok "${u}: значение применено на лету (процессов: ${n})."
        else
            warn "${u}: на лету применить не удалось, значение вступит в силу после перезапуска службы."
        fi
    fi
done

# Проверка результата: значение по конфигу и фактическое в памяти
echo
log "Проверка результата..."
CONFLICT=0
for u in $UNITS; do
    cfg=$(systemctl show -p OOMScoreAdjust --value "${u}.service" 2>/dev/null)
    pid=$(systemctl show -p MainPID --value "${u}.service" 2>/dev/null)
    live="—"
    if [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 0 ] && [ -r "/proc/${pid}/oom_score_adj" ]; then
        live=$(cat "/proc/${pid}/oom_score_adj")
    fi
    if [ -n "$cfg" ] && [ "$cfg" != "$ADJ" ]; then
        warn "${u}: по конфигу ${cfg}, а не ${ADJ} — значение переопределяет другой drop-in."
        CONFLICT=1
    elif [ "$live" != "—" ] && [ "$live" != "$ADJ" ]; then
        warn "${u}: по конфигу ${cfg}, в памяти ${live} (применится после перезапуска)."
    else
        ok "${u}: по конфигу ${cfg}, в памяти ${live}."
    fi
done

echo
echo -e "${B_GREEN}${BOLD}Готово${NC}"
echo -e "${B_GREEN}Защищённые службы: ${UNITS}${NC}"
echo -e "${B_GREEN}OOMScoreAdjust: ${ADJ}${NC}"
echo
echo -e "${B_CYAN}Значение по конфигу:${NC} ${BOLD}systemctl show -p OOMScoreAdjust x-ui${NC}"
echo -e "${B_CYAN}Значение в памяти:${NC} ${BOLD}cat /proc/\$(systemctl show -p MainPID --value x-ui)/oom_score_adj${NC}"
echo -e "${B_CYAN}Итоговая конфигурация юнита:${NC} ${BOLD}systemctl cat x-ui${NC}"
echo -e "${B_CYAN}Срабатывания OOM-киллера:${NC} ${BOLD}journalctl -k | grep -i 'out of memory'${NC}"
echo
if [ "$CONFLICT" -eq 1 ]; then
    warn "Часть значений переопределена другими drop-in файлами — смотрите 'systemctl cat <служба>':"
    warn "файлы читаются по алфавиту, поздний побеждает."
fi
warn "Защита снижает шанс убийства службы, но не устраняет нехватку памяти: при реальном"
warn "исчерпании ядро убьёт другой процесс. Если RAM не хватает — добавьте swap или zram."
