#!/usr/bin/env bash
set -uo pipefail

export LC_ALL=C
PASS=0
FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf '  [OK]   %s\n' "$desc"
        ((PASS += 1))
    else
        printf "  [FAIL] %s (ожидалось: '%s', получено: '%s')\n" "$desc" "$expected" "$actual"
        ((FAIL += 1))
    fi
}

if ! sudo -v; then
    printf 'Не удалось получить права sudo для аудита.\n' >&2
    exit 1
fi

printf 'Аудит конфигурации: %s, %s\n' "$(hostname -f)" "$(date '+%Y-%m-%d %H:%M')"
printf '[1] Служба SSH\n'
ssh_config="$(sudo /usr/sbin/sshd -T)"
check 'Вход от имени root запрещён' 'no' "$(awk '/^permitrootlogin / {print $2}' <<< "$ssh_config")"
check 'Парольная аутентификация отключена' 'no' "$(awk '/^passwordauthentication / {print $2}' <<< "$ssh_config")"
port="$(awk '/^port / {print $2}' <<< "$ssh_config")"
nonstandard_port=no
if [[ "$port" =~ ^[0-9]+$ && "$port" != 22 ]]; then
    nonstandard_port=yes
fi
check 'SSH использует нестандартный порт' 'yes' "$nonstandard_port"
check 'MaxAuthTries равно 3' '3' "$(awk '/^maxauthtries / {print $2}' <<< "$ssh_config")"

printf '[2] Межсетевой экран\n'
check 'Межсетевой экран активен' 'active' "$(sudo ufw status | awk '/^Status:/ {print $2}')"
check 'Входящие соединения по умолчанию запрещены' 'deny' "$(sudo ufw status verbose | awk '/^Default:/ {print $2}')"

printf '[3] Учётные записи\n'
awk -F: '$3 >= 1000 && $3 < 65534 {printf "    %s (uid=%s)\n", $1, $3}' /etc/passwd
printf '[4] Веб-сервер\n'
check 'Служба Nginx активна' 'active' "$(systemctl is-active nginx)"
sudo nginx -t >/dev/null 2>&1
check 'Конфигурация Nginx корректна' '0' "$?"
cert_min_days="${1:-${CERT_MIN_DAYS:-30}}"
if [[ ! "$cert_min_days" =~ ^[0-9]+$ ]] || (( cert_min_days > 36500 )); then
    printf 'CERT_MIN_DAYS должен быть целым числом от 0 до 36500.\n' >&2
    exit 1
fi
openssl x509 -in /etc/ssl/certs/devops.crt -noout -checkend "$((cert_min_days * 86400))" >/dev/null 2>&1
check "Сертификат действует минимум ${cert_min_days} дней" '0' "$?"
unsafe_files="$(find /var/www/devops-site -perm -o+w -print 2>&1)"
find_status=$?
key_mode="$(sudo stat -c '%a' /etc/ssl/private/devops.key 2>/dev/null)"
permissions_ok=no
if [[ "$find_status" -eq 0 && -z "$unsafe_files" && "$key_mode" == 600 ]]; then
    permissions_ok=yes
fi
check 'Нет записи для всех и ключ имеет права 600' 'yes' "$permissions_ok"
printf '[5] Контейнеризация\n'
check 'Служба Docker активна' 'active' "$(systemctl is-active docker)"
check 'СУБД находится в состоянии healthy' 'healthy' "$(sudo docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null)"
listeners="$(ss -H -tln 2>/dev/null)"
listeners_status=$?
ports_ok=no
if [[ "$listeners_status" -eq 0 ]]; then
    unsafe_listeners="$(awk '$4 ~ /:(5000|5432)$/ && $4 !~ /^127[.]0[.]0[.]1:(5000|5432)$/ {print $4}' <<< "$listeners")"
    if [[ -z "$unsafe_listeners" ]]; then
        ports_ok=yes
    fi
fi
check 'Порты 5000 и 5432 не опубликованы за пределами loopback' 'yes' "$ports_ok"
check 'Файл окружения имеет права 600' '600' "$(sudo stat -c '%a' /home/devops/app/.env 2>/dev/null)"
printf 'Пройдено: %s, не пройдено: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
