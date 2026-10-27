# Практическая работа №5: devops-vm

## 1. Параметры виртуальной машины

VirtualBox 7.2.20 на macOS ARM64; Ubuntu Server 24.04.5 LTS ARM64,
обычная установка, не minimized. Имя `devops-vm`, 2 CPU, 2048 МБ RAM,
динамический диск VDI 25 ГБ. Диск расположен в `~/VirtualBox VMs/devops-vm/`.
После установки выполнены `sudo apt-get update` и `sudo apt-get upgrade -y`.

## 2. Сетевые интерфейсы

| Интерфейс | Режим | Адрес | Назначение |
|---|---|---|---|
| enp0s8 | NAT | 10.0.2.15/24, DHCP | Интернет и SSH через проброс |
| enp0s9 | Host-only, devops-hostonly | 192.168.56.101/24, статический | Соединение Mac с VM |
| bridge100 на Mac | Host-only | 192.168.56.1/24 | Хост в изолированной сети |

Netplan сопоставляет интерфейсы по MAC: NAT `08:00:27:ec:df:7e`,
Host-only `08:00:27:4e:14:c0`. Шлюз по умолчанию только через NAT.
В `/etc/hosts` Mac нужна строка `192.168.56.101 devops.local`.
В `/etc/hosts` VM: `127.0.1.1 devops-vm.devops.local devops-vm`.

## 3. Проброс портов

Первоначально `127.0.0.1:2222 → guest:22`.
После hardening: `127.0.0.1:2222 → guest:2222`, правило `ssh` адаптера 1.
Привязка к loopback не открывает SSH VM для внешней сети Mac.

## 4. Учётные записи и клиент

`student` (UID 1000) — первоначальная учётная запись, входит в sudo.
`devops` (UID 1001) — рабочая учётная запись, группы devops и sudo.
SSH разрешён только devops и только по ключу. Пароль devops нужен для sudo,
пароль student — для локальной консоли. Пароли хранятся локально вне репозитория.

Отдельный ключ клиента: `~/.ssh/devops_vm`, public key `~/.ssh/devops_vm.pub`.
Fingerprint: `SHA256:O767aTP2feZHZ14iwTLILk5mRb584C5d9l6+ZXe5Gec`.
Серверный Ed25519 fingerprint сверён через консоль VirtualBox:
`SHA256:7ojUWQDp1ZSwwlhMXgLYv/7drCyv8jo7A4nEjdLV8Fw`.
На сервере `.ssh` имеет права 700, `authorized_keys` — 600, владелец devops.

Клиентский `~/.ssh/config`:

```sshconfig
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes

Host devops.local
    HostName devops.local
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

## 5. Служба SSH

Резервная копия: `/etc/ssh/sshd_config.backup`.
Рабочий файл: `/etc/ssh/sshd_config.d/99-hardening.conf`:

```text
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers devops
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

В `/etc/ssh/sshd_config.d/50-cloud-init.conf` закомментирован
`PasswordAuthentication yes`: OpenSSH использует первое найденное значение.
`ssh.socket` отключён, `ssh.service` включён. После `sudo sshd -t`
служба перезапущена, `ss` подтвердил порт 2222.
Root и соединение с `PubkeyAuthentication=no` получают отказ, exit code 255.
Журнал показывает отказ root из-за AllowUsers и успешную аутентификацию devops.

## 6. Межсетевой экран

UFW active; default deny incoming, allow outgoing; logging medium.
Правила IPv4 и IPv6: 2222/tcp LIMIT, 80/tcp ALLOW, 443/tcp ALLOW.
Проверка закрытого 8080/tcp через временный NAT-проброс дала timeout и запись
`UFW BLOCK SRC=10.0.2.2 DST=10.0.2.15 PROTO=TCP DPT=8080`.
Временный проброс удалён. Лимит защищает от частых новых соединений;
он не является ограничением числа неверных паролей внутри одной SSH-сессии.

## 7. Снимки состояния

| Имя | Момент создания |
|---|---|
| 01-clean-install | После установки, обновления и проверки сети; SSH ещё на 22 |
| 02-keys-configured | devops создан, ключ установлен, вход по ключу проверен |
| 03-ssh-hardened | SSH на 2222, пароль и root запрещены, тесты отказа прошли |

Снимки создавались на выключенной VM. UFW и FQDN настроены после третьего снимка.

## 8. Веб-сервер

Ubuntu-пакеты: nginx и rsync. Nginx 1.24.0; служба включена в автозагрузку.
Конфигурация: /etc/nginx/sites-available/devops-site, активная ссылка
/etc/nginx/sites-enabled/devops-site. Ссылка sites-enabled/default удалена;
исходный sites-available/default сохранён.

Каталог /var/www/devops-site принадлежит devops:devops. Каталоги 755,
файлы 644. Главный процесс Nginx — root, рабочие — www-data.
www-data читает файлы, но не может изменять их или создавать новые.

Сертификат /etc/ssl/certs/devops.crt: root:root, 644.
Закрытый ключ /etc/ssl/private/devops.key: root:root, 600;
ключ остаётся только на сервере и не включается в Git.
Срок действия сертификата — 365 дней, SAN DNS:devops.local.
Команда создания:

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key \
  -out /etc/ssl/certs/devops.crt \
  -subj "/CN=devops.local" \
  -addext "subjectAltName=DNS:devops.local"
sudo chmod 600 /etc/ssl/private/devops.key
sudo chmod 644 /etc/ssl/certs/devops.crt
```

Конфигурация ресурса:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name devops.local;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name devops.local;
    ssl_certificate /etc/ssl/certs/devops.crt;
    ssl_certificate_key /etc/ssl/private/devops.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/devops-site;
    index index.html;
    location / { try_files $uri $uri/ =404; }
    error_page 404 /404.html;
    access_log /var/log/nginx/devops-site.access.log;
    error_log /var/log/nginx/devops-site.error.log;
}
```

После изменения: sudo nginx -t, затем sudo systemctl reload nginx.
HTTP перенаправляется кодом 301 на HTTPS. HSTS не добавляется.
Открыты 80 и 443 в UFW. Снимок 04-nginx-https создан после проверки TLS.
В блоке перенаправления используется общий access.log; отдельный журнал
/var/log/nginx/devops-site.access.log относится к HTTPS-блоку.
Журнал ошибок: /var/log/nginx/devops-site.error.log.

На Mac открытый сертификат получен по доверенному SSH-каналу в ~/devops.crt.
Проверка без отключения TLS: curl --cacert ~/devops.crt -I https://devops.local.
Обычный curl отклоняет самоподписанный сертификат с кодом 60.

Содержимое хранится в site/. Доставка: scripts/deploy.sh; сначала
scripts/deploy.sh --dry-run. Скрипт работает из подкаталога репозитория,
не допускает незакоммиченных изменений и отсутствующего index.html,
использует одно SSH-соединение rsync с BatchMode=yes, затем curl -f с --cacert.
Для openrsync macOS использована эквивалентная символьная запись прав
--chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r (755/644).
REMOTE, SITE_URL и CA_CERT можно переопределить окружением.

Аудит дополнен четырьмя проверками Nginx, синтаксиса, срока сертификата и прав.
Штатный запуск: sudo bash scripts/audit.sh --stage web — 10 OK, exit 0.
Негативная проверка срока: sudo bash scripts/audit.sh --stage web 400 — exit 1.
При правах 666 на index.html аудит также возвращает 1.
После опытов содержимое и права восстановлены штатным деплоем.

## 9. Контейнеризация

Docker Engine Community установлен из официального APT-репозитория
https://download.docker.com/linux/ubuntu для Ubuntu noble/arm64.
Установлены docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin,
docker-compose-plugin. Пакет docker.io не используется.
Версия Engine: 29.9.2. В группу docker включён devops, уже имеющий sudo.
После изменения группы требуется новая сессия или newgrp docker.

Проект расположен в /home/devops/app. Исходники хранятся в app/ репозитория.
Доставка с Mac из корня репозитория:

```bash
rsync -avz --delete --exclude=.env --dry-run app/ devops:app/
rsync -avz --delete --exclude=.env app/ devops:app/
```

.env создаётся только на сервере, принадлежит devops:docker, права 600.
Он исключён из Git и контекста сборки. --exclude=.env сохраняет его при rsync
с --delete. Пароль не копируется на Mac и не включается в отчёт.
Первичная настройка внутри VM:

```bash
cd /home/devops/app
umask 077
cp .env.example .env
chmod 600 .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env
docker compose up -d --build
docker compose ps
```

Приложение devops-app:1.0 использует Python 3.12, Flask, gunicorn
и psycopg2-binary; запускается пользователем app, а не root.
Для app.py и requirements.txt владелец root и права 644.
Сначала копируется requirements.txt и устанавливаются зависимости, затем app.py:
изменение текста ответа сохраняет кэш установки зависимостей.

PostgreSQL postgres:16-alpine хранит данные в именованном томе app_db_data
(/var/lib/postgresql/data). Пользовательская bridge-сеть app_backend
разрешает имя db через DNS Docker. DB_HOST=db, имя базы и пользователя app.
Порт 5432 не публикуется. Приложение публикуется только на
127.0.0.1:5000:5000. В depends_on используется service_healthy
и pg_isready; interval 5s, timeout 3s, retries 5.

В HTTPS-блок /etc/nginx/sites-available/devops-site добавлено:

```nginx
location /app/ {
    proxy_pass http://127.0.0.1:5000/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Завершающий / в proxy_pass удаляет префикс /app/ при передаче запроса.
Статический location /, сертификат и перенаправление HTTP сохранены.
После проверки sudo nginx -t выполнить sudo systemctl reload nginx.
Проверка с Mac:

```bash
curl --cacert ~/devops.crt https://devops.local/app/
curl --cacert ~/devops.crt https://devops.local/app/health
curl --cacert ~/devops.crt -I https://devops.local/
```

docker compose down сохраняет том и счётчик. down -v удаляет данные —
используется только для явно разрешённого опыта на учебном томе.
Для штатного перезапуска применять docker compose up -d.
При 502 проверить docker compose ps, docker compose logs app,
curl http://127.0.0.1:5000/health и журнал devops-site.error.log.
Конфигурация с публикацией 0.0.0.0 небезопасна: правила Docker обходят UFW.

Аудит содержит раздел [5]: Docker active, app-db-1 healthy, отсутствие
слушающих 5000/5432 за пределами 127.0.0.1, .env mode 600.
Запуск sudo bash /home/devops/audit.sh. Рабочий итог — 14 OK, код 0.
Снимок 05-docker-compose сохраняет проект для контрольной №2.
Не удалять проект, итоговый том и снимки после сдачи.

Для проверки HTTPS из консоли VM в /etc/hosts добавлено
`192.168.56.101 devops.local`. Используется локальный сертификат
`/etc/ssl/certs/devops.crt` с параметром curl --cacert.
Проверка с Mac выполнена в Chrome: /app/ возвращает персонализированный
ответ и счётчик, а временный :5001/health возвращал ok без правила UFW.

## 10. Восстановление из 01-clean-install за 10 минут

На Mac выключить VM, восстановить снимок, вернуть исходный проброс и запустить:

```bash
VBoxManage snapshot devops-vm restore 01-clean-install
VBoxManage modifyvm devops-vm --natpf1 delete ssh
VBoxManage modifyvm devops-vm --natpf1 'ssh,tcp,127.0.0.1,2222,,22'
VBoxManage startvm devops-vm --type gui
```

Снимок сохраняет прежний серверный ключ. Если fingerprint изменился,
сначала сверить его в консоли, не удалять known_hosts вслепую.
Существующий ключ `~/.ssh/devops_vm` повторно генерировать не нужно.
На Mac из корня репозитория скопировать public key и аудит:

```bash
scp -P 2222 ~/.ssh/devops_vm.pub student@127.0.0.1:/tmp/devops_vm.pub
scp -P 2222 scripts/audit.sh student@127.0.0.1:/tmp/audit.sh
ssh -p 2222 student@127.0.0.1
```

В открытой SSH-сессии student выполнить (passwd интерактивно задаёт пароль sudo):

```bash
sudo useradd -m -s /bin/bash devops
sudo usermod -aG sudo devops
sudo passwd devops
sudo install -d -m 700 -o devops -g devops /home/devops/.ssh
sudo install -m 600 -o devops -g devops /tmp/devops_vm.pub /home/devops/.ssh/authorized_keys
sudo install -m 755 -o devops -g devops /tmp/audit.sh /home/devops/audit.sh
```

В другом окне Mac проверить `ssh devops`. Исходную сессию student сохранить.
В ней выполнить:

```bash
sudo cp -p /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
sudo cp -p /etc/ssh/sshd_config.d/50-cloud-init.conf /etc/ssh/sshd_config.d/50-cloud-init.conf.backup
sudo sed -i 's/^PasswordAuthentication yes/# PasswordAuthentication yes/' /etc/ssh/sshd_config.d/50-cloud-init.conf
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf >/dev/null <<'EOF'
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers devops
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
sudo sshd -t && sudo systemctl disable --now ssh.socket
sudo systemctl enable ssh.service
sudo systemctl restart ssh.service
sudo ss -lntp | grep sshd
```

На Mac заменить проброс в работающей VM:

```bash
VBoxManage controlvm devops-vm natpf1 delete ssh
VBoxManage controlvm devops-vm natpf1 'ssh,tcp,127.0.0.1,2222,,2222'
ssh devops
```

После успешного нового входа devops выполнить в нём:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 2222/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
sudo ufw logging medium
sudo hostnamectl set-hostname devops-vm
sudo sed -i '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts
printf '%s\n' '127.0.1.1 devops-vm.devops.local devops-vm' | sudo tee -a /etc/hosts
hostname -f
sudo sshd -T | grep -E '^(port|permitrootlogin|passwordauthentication|maxauthtries) '
sudo ufw status verbose
sudo bash /home/devops/audit.sh --stage ssh
```

На Mac, если ещё не сделано, добавить hosts и разрешить Codex/Terminal локальную сеть
в настройках macOS:

```bash
printf '\n192.168.56.101 devops.local\n' | sudo tee -a /etc/hosts
ssh -i ~/.ssh/devops_vm -p 2222 devops@devops.local
```

Закрыть исходную сессию только после проверки нового входа.
При потере SSH использовать консоль VirtualBox или откат на снимок.

## 11. Проверка audit.sh

После восстановления только ПР №5 запускать `audit.sh --stage ssh`:
6 OK, 0 FAIL, exit 0. Он не требует ещё не установленных Nginx и Docker.
После ПР №6 запускать `audit.sh --stage web`: 10 OK.
После ПР №7 запускать `audit.sh` или `audit.sh --stage docker`: 14 OK.
Для негативной проверки срока сертификата: `audit.sh --stage web 400`.
Этап выбирается явно; отсутствие требуемой службы не пропускается автоматически.
При временном `MaxAuthTries 10`: 5 OK, 1 FAIL, exit 1.
После проверки восстановлено `MaxAuthTries 3`; ослабленная конфигурация
не применялась к работающей службе.

Репозиторий: https://github.com/FireFly4ik/devops-course-2026
