#!/bin/bash
set -x
# --- БЛОК НАСТРОЕК ---
EMAIL_ADMIN="admin@example.com"      # Аккаунт администратора CGP
EMAIL_REPORT="reports@example.com"   # Куда слать отчеты о работе
SMTP_PASS="YourSecurePassword"       # Пароль администратора CGP
IP_CGP="127.0.0.1"                   # IP сервера CommuniGate
CLI_PORT="8100"                      # Порт CLI CommuniGate (по умолчанию 8100)
SMTP_PORT="25"                       # Порт SMTP для отправки отчетов
HELO_HOST="example.com"           # HELO для SMTP сессии

LOG_FILE="/var/log/cgp_master.log"
REQUIRED_PACKAGES="certbot curl lsof openssl"


# --- ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ---
REPORT_DATA=()
mkdir -p "$(dirname "$LOG_FILE")"

log_msg() { 
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    REPORT_DATA+=("$1")
    [ -t 0 ] && echo -e "$1"
}

# --- ПРОВЕРКА ЗАВИСИМОСТЕЙ ---
check_dependencies() {
    local missing=()
    for pkg in $REQUIRED_PACKAGES; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "\e[31m[ERROR] Отсутствуют необходимые пакеты: ${missing[*]}\e[0m"
        echo "Установите их: apt update && apt install ${missing[*]} -y (или snap install certbot)"
        exit 1
    fi
}

# --- ФУНКЦИЯ ОТПРАВКИ ОТЧЕТА ---
send_notification() {
    [ -t 0 ] && return 0 
    local subject
    subject="SSL Report: $(hostname) - $(date +%F)"
    local temp_mail="/tmp/ssl_mail.txt"
    {
        echo "To: $EMAIL_REPORT"
        echo "From: $EMAIL_ADMIN"
        echo "Subject: $subject"
        echo "Content-Type: text/html; charset=UTF-8"
        echo ""
        echo "<html><body style='font-family: sans-serif;'>"
        echo "<h2>Отчет автоматического обновления SSL</h2><hr>"
        for line in "${REPORT_DATA[@]}"; do
            if [[ "$line" == *"[NEW]"* ]] || [[ "$line" == *"[OK]"* ]]; then echo "<p style='color:green;'>$line</p>"
            elif [[ "$line" == *"[CRITICAL]"* ]] || [[ "$line" == *"[FAIL]"* ]] || [[ "$line" == *"[ERROR]"* ]]; then echo "<p style='color:red;'><b>$line</b></p>"
            elif [[ "$line" == *"[INFO]"* ]]; then echo "<p style='color:blue;'>$line</p>"
            else echo "<p>$line</p>"
            fi
        done
        echo "<hr><p>Дата запуска: $(date)</p></body></html>"
    } > "$temp_mail"
    
    curl --url "smtp://$IP_CGP:$SMTP_PORT" --mail-from "$EMAIL_ADMIN" --mail-rcpt "$EMAIL_REPORT" \
         --upload-file "$temp_mail" --user "$EMAIL_ADMIN:$SMTP_PASS" --mail-auth "$EMAIL_ADMIN" \
         -k --silent --show-error >> "$LOG_FILE" 2>&1
    rm -f "$temp_mail"
}

fetch_domains_from_cgp() {
    local raw_list
    if ! raw_list=$(curl -s -u "$EMAIL_ADMIN:$SMTP_PASS" -k "http://$IP_CGP:$CLI_PORT/cli/?command=listdomains") || [ -z "$raw_list" ]; then 
        return 1
    fi
    DOMAINS_BASE=$(echo "$raw_list" | sed 's/[^a-zA-Z0-9.-]/ /g' | xargs)
    return 0
}

get_port_owner() { lsof -i :80 -sTCP:LISTEN -t | xargs ps -o comm= -p 2>/dev/null | head -n 1 | tr -d ' '; }

# --- ЗАДАЧИ ---
task_get_certs() {
    log_msg ">>> 1. Проверка и получение сертификатов (Let's Encrypt)..."
    fetch_domains_from_cgp || return 1
    local owner
    owner=$(get_port_owner)
    local services_to_start=()
    
    if [ -n "$owner" ]; then
        declare -A CUSTOM_STOP=( ["apache2"]="systemctl stop apache2" ["nginx"]="systemctl stop nginx" ["caddy"]="systemctl stop caddy" )
        if [[ -n "${CUSTOM_STOP[$owner]}" ]]; then
            log_msg "Остановка порта 80 ($owner)..."
            ${CUSTOM_STOP[$owner]} >> "$LOG_FILE" 2>&1
            services_to_start+=("$owner")
        fi
    fi

    for domain in $DOMAINS_BASE; do
        local cb_out
        cb_out="/tmp/cb_$(date +%s).log"
        # Запрос сертификата. Если лимиты исчерпаны, добавьте сюда доп. домен как обсуждали
        if certbot certonly --standalone -d "mail.$domain" --key-type rsa --rsa-key-size 2048 --non-interactive --agree-tos --email "$EMAIL_ADMIN" > "$cb_out" 2>&1; then
            if grep -qE "Certificate not yet due for renewal|Your certificate stays valid" "$cb_out"; then 
                log_msg "[INFO] mail.$domain: Файл еще свежий."
            else 
                log_msg "[NEW] mail.$domain: ПОЛУЧЕН НОВЫЙ сертификат!"
            fi
        else 
            log_msg "[FAIL] mail.$domain: ОШИБКА Certbot! (Проверьте логи или лимиты)"
        fi
        rm -f "$cb_out"
    done

    for svc in "${services_to_start[@]}"; do systemctl start "$svc"; done
}

task_install_to_cgp() {
    log_msg ">>> 2. Синхронизация с CommuniGate Pro..."
    fetch_domains_from_cgp || return 1
    for domain in $DOMAINS_BASE; do
        local path
        # Поиск актуальной папки (берем последнюю по алфавиту, чтобы избежать проблем с -0001)
        # shellcheck disable=SC2012
        path=$(ls -d /etc/letsencrypt/live/mail."$domain"* 2>/dev/null | tail -n 1)
        
        if [ -z "$path" ] || [ ! -d "$path" ]; then
            log_msg "[CRITICAL] $domain: Папка сертификата не найдена."
            continue
        fi

        local key crt chain CMD resp
        key=$(openssl rsa -in "$path/privkey.pem" -traditional 2>/dev/null | grep -v '\-\-' | tr -d '\n\r ')
        crt=$(cat "$path/cert.pem" 2>/dev/null | grep -v '\-\-' | tr -d '\n\r ')
        chain=$(cat "$path/fullchain.pem" 2>/dev/null | grep -v '\-\-' | tr -d '\n\r ')

        if [ -z "$key" ] || [ -z "$crt" ]; then
            log_msg "[CRITICAL] $domain: Ошибка чтения файлов в $path."
            continue
        fi

        CMD="command=updatedomainsettings ${domain} {PrivateSecureKey=[${key}];SecureCertificate=[${crt}];CAChain=[${chain}];}"
        if resp=$(curl -s -u "$EMAIL_ADMIN:$SMTP_PASS" -k "http://$IP_CGP:$CLI_PORT/cli/" --data-urlencode "$CMD") && [[ ! "$resp" =~ "ERROR" ]]; then 
            log_msg "[OK] $domain: Успешно синхронизирован."
        else 
            log_msg "[ERROR] $domain: Ошибка CGP: $resp"
        fi
    done
}

task_cleanup_manual() {
    echo -e "\n=== ОЧИСТКА СЕРТИФИКАТОВ ==="
    echo "1) Удалить ОДИН (ввод имени)"
    echo "2) Очистка битых конфигов (авто)"
    echo "3) Удалить ВСЁ (полный сброс)"
    echo "0) Назад"
    read -r -p "> " clean_ch
    case "$clean_ch" in
        1)
            certbot certificates
            read -r -p "Имя сертификата для удаления: " cert_to_del
            [ -n "$cert_to_del" ] && certbot delete --cert-name "$cert_to_del"
            ;;
        2)
            log_msg "Очистка битых файлов конфигурации..."
            find /etc/letsencrypt/renewal/ -name "*.conf" -type f | while read -r conf; do
                local cname
                cname=$(basename "$conf" .conf)
                if ! certbot certificates --cert-name "$cname" >/dev/null 2>&1; then
                    rm -f "$conf"
                    rm -rf "/etc/letsencrypt/live/$cname" "/etc/letsencrypt/archive/$cname"
                    log_msg "Удален мусор: $cname"
                fi
            done
            ;;
        3)
            local cert_list
            cert_list=$(certbot certificates 2>/dev/null | grep "Certificate Name" | awk '{print $3}')
            if [ -z "$cert_list" ]; then echo "Список пуст."; else
                read -r -p "Удалить ВСЕ сертификаты? [y/N]: " confirm
                [[ "$confirm" == "y" ]] && for c in $cert_list; do certbot delete --cert-name "$c"; done
            fi
            ;;
    esac
}

task_show_status() {
    log_msg ">>> 3. Статус сертификатов:"
    local cert_output
    cert_output=$(certbot certificates 2>/dev/null)
    echo "$cert_output" | grep -E "Certificate Name:|Expiry Date:" | sed 's/Expiry Date:/Истекает:/g' | awk '{$1=$1;print}' | while read -r line; do
        log_msg "   $line"
    done
}

# --- ЗАПУСК ---
check_dependencies

if [ -t 0 ]; then
    while true; do
        echo -e "\n1) ПОЛНЫЙ ЦИКЛ\n2) Получить (Certbot)\n3) Установить (Sync CGP)\n4) Срок действия\n5) ОЧИСТКА\n0) Выход"
        read -r -p "Выберите пункт: " ch
        case "$ch" in
            1) task_get_certs; task_install_to_cgp; task_show_status ;;
            2) task_get_certs ;;
            3) task_install_to_cgp ;;
            4) task_show_status ;;
            5) task_cleanup_manual ;;
            0) exit 0 ;;
        esac
    done
else
    # Автоматический режим (для Systemd/Cron)
    task_get_certs
    task_install_to_cgp
    task_show_status
    send_notification
fi
