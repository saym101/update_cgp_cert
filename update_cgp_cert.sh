#!/bin/bash
# set -x
# --- БЛОК НАСТРОЕК ---
EMAIL_ADMIN="admin@example.com"      # Аккаунт администратора CGP
EMAIL_REPORT="reports@example.com"   # Куда слать отчеты о работе
SMTP_PASS="YourSecurePassword"       # Пароль администратора CGP
IP_CGP="127.0.0.1"                   # IP сервера CommuniGate
CLI_PORT="8100"                      # Порт CLI CommuniGate (по умолчанию 8100)
SMTP_PORT="25"                       # Порт SMTP для отправки отчетов
HELO_HOST="example.com"           # HELO для SMTP сессии
LOG_FILE="/var/log/cgp_master/cgp_master.log"    # Место хранения лог файла
LOG_RETENTION_DAYS=14    # Срок ротации логов
REQUIRED_PACKAGES="certbot curl lsof openssl python3" 

LOG_FILE="/var/log/cgp_master.log"
REQUIRED_PACKAGES="certbot curl lsof openssl"

# Список доменов для ИСКЛЮЧЕНИЯ из синхронизации с CGP (через пробел)
EXCLUDE_DOMAINS_SYNC="exhample"

# --- ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ---
REPORT_DATA=()
mkdir -p "$(dirname "$LOG_FILE")"

# --- РОТАЦИЯ ЛОГОВ (хранить 14 дней) ---
rotate_log() {
    [ ! -f "$LOG_FILE" ] && return 0
    local dir base stamp
    dir=$(dirname "$LOG_FILE")
    base=$(basename "$LOG_FILE" .log)
    stamp=$(date '+%Y-%m-%d_%H-%M-%S')
    mv "$LOG_FILE" "${dir}/${base}_${stamp}.log"
    find "$dir" -maxdepth 1 -type f -name "${base}_*.log" -mtime +"$LOG_RETENTION_DAYS" -delete
}

# --- КОНВЕРТАЦИЯ КИРИЛЛИЧЕСКОГО ДОМЕНА В PUNYCODE ---
to_punycode() {
    local domain="$1"
    python3 -c '
import sys
domain = sys.argv[1].strip().strip(".")
parts = [p for p in domain.split(".") if p]
print(".".join(p.encode("idna").decode("ascii") for p in parts))
' "$domain" 2>/dev/null || printf '%s\n' "$domain"
}

log_msg() { 
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
    REPORT_DATA+=("$1")
    
    # Если запущены в терминале, выводим с цветом
    if [ -t 0 ]; then
        if [[ "$1" == *"[SKIP]"* ]]; then
            echo -e "\e[1;31m$1\e[0m" # Жирный красный для SKIP
        elif [[ "$1" == *"[OK]"* ]] || [[ "$1" == *"[NEW]"* ]]; then
            echo -e "\e[32m$1\e[0m"   # Зеленый для успеха
        elif [[ "$1" == *"[FAIL]"* ]] || [[ "$1" == *"[ERROR]"* ]] || [[ "$1" == *"[CRITICAL]"* ]]; then
            echo -e "\e[31m$1\e[0m"   # Обычный красный для ошибок
        elif [[ "$1" == *"[INFO]"* ]]; then
            echo -e "\e[34m$1\e[0m"   # Синий для инфо
        else
            echo -e "$1"
        fi
    fi
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
            elif [[ "$line" == *"[SKIP]"* ]]; then echo "<p style='color:orange;'>$line</p>"
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
    local raw_list cleaned domains
    if ! raw_list=$(curl -s -u "$EMAIL_ADMIN:$SMTP_PASS" -k "http://$IP_CGP:$CLI_PORT/cli/?command=listdomains") || [ -z "$raw_list" ]; then 
        return 1
    fi
    cleaned=${raw_list//$'\r'/}
    cleaned=${cleaned//$'\n'/}
    cleaned=${cleaned#\(}
    cleaned=${cleaned%\)}
    domains=$(printf '%s\n' "$cleaned" \
        | tr ',' '\n' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | sed '/^$/d' \
        | tr '\n' ' ')
    DOMAINS_BASE=${domains% }
    [ -n "$DOMAINS_BASE" ]
}

get_port_owner() { lsof -i :80 -sTCP:LISTEN -t | xargs ps -o comm= -p 2>/dev/null | head -n 1 | tr -d ' '; }

# Открыть/закрыть порт 80 в iptables для Let's Encrypt
FW_80_OPENED_BY_SCRIPT=0
fw_open_80()  {
    FW_80_OPENED_BY_SCRIPT=0
    if ! command -v iptables >/dev/null 2>&1; then
        log_msg "[INFO] Файервол: iptables не найден, открытие порта 80 пропущено."
        return 0
    fi
    if ! iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null; then
        if iptables -I INPUT -p tcp --dport 80 -j ACCEPT >> "$LOG_FILE" 2>&1; then
            FW_80_OPENED_BY_SCRIPT=1
            log_msg "[INFO] Файервол: открыт порт 80 для Let's Encrypt."
        else
            log_msg "[WARN] Файервол: не удалось открыть порт 80 через iptables."
        fi
    fi
}
fw_close_80() {
    [ "${FW_80_OPENED_BY_SCRIPT:-0}" -eq 1 ] || return 0
    if command -v iptables >/dev/null 2>&1 && iptables -D INPUT -p tcp --dport 80 -j ACCEPT >> "$LOG_FILE" 2>&1; then
        log_msg "[INFO] Файервол: порт 80 закрыт."
    fi
    FW_80_OPENED_BY_SCRIPT=0
}

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
    fw_open_80
    for domain in $DOMAINS_BASE; do
        local puny_domain mail_domain cb_out
        puny_domain=$(to_punycode "$domain")
        mail_domain="mail.${puny_domain}"
        cb_out="/tmp/cb_$(date +%s).log"
        if certbot certonly --standalone -d "$mail_domain" --key-type rsa --rsa-key-size 2048 \
            --non-interactive --agree-tos --email "$EMAIL_ADMIN" > "$cb_out" 2>&1; then
            if grep -qE "Certificate not yet due for renewal|Your certificate stays valid" "$cb_out"; then
                log_msg "[INFO] $mail_domain: Файл свежий."
            else
                log_msg "[NEW] $mail_domain: ПОЛУЧЕН НОВЫЙ сертификат!"
            fi
        else
            log_msg "[FAIL] $mail_domain: ОШИБКА Certbot!"
            grep -E "Error|error|detail|DETAIL|Problem|problem" "$cb_out" 2>/dev/null \
                | while IFS= read -r errline; do log_msg "       $errline"; done
        fi
        rm -f "$cb_out"
    done
    fw_close_80
    for svc in "${services_to_start[@]}"; do systemctl start "$svc"; done
}

task_install_to_cgp() {
    log_msg ">>> 2. Синхронизация с CommuniGate Pro..."
    fetch_domains_from_cgp || return 1
    for domain in $DOMAINS_BASE; do
        # ПРОВЕРКА ИСКЛЮЧЕНИЙ
        if [[ " $EXCLUDE_DOMAINS_SYNC " =~ " $domain " ]]; then
            log_msg "[SKIP] $domain: Пропуск синхронизации (в списке исключений)."
            continue
        fi

        local puny_domain path key crt chain CMD resp
        puny_domain=$(to_punycode "$domain")

        # shellcheck disable=SC2012
        path=$(ls -d /etc/letsencrypt/live/mail."${puny_domain}"* 2>/dev/null | tail -n 1)
        if [ -z "$path" ] || [ ! -d "$path" ]; then
            log_msg "[CRITICAL] $domain (${puny_domain}): Папка не найдена."
            continue
        fi
        key=$(openssl rsa -in "$path/privkey.pem" -traditional 2>/dev/null | grep -v '\-\-' | tr -d '\n\r ')
        crt=$(cat "$path/cert.pem"        2>/dev/null | grep -v '\-\-' | tr -d '\n\r ')
        chain=$(cat "$path/fullchain.pem" 2>/dev/null | grep -v '\-\-' | tr -d '\n\r ')
        if [ -z "$key" ] || [ -z "$crt" ]; then
            log_msg "[CRITICAL] $domain: Файлы в $path пустые."
            continue
        fi
        # Для CGP используем оригинальное имя домена (CGP хранит его именно так)
        CMD="command=updatedomainsettings ${domain} {PrivateSecureKey=[${key}];SecureCertificate=[${crt}];CAChain=[${chain}];}"
        if resp=$(curl -s -u "$EMAIL_ADMIN:$SMTP_PASS" -k "http://$IP_CGP:$CLI_PORT/cli/" \
                  --data-urlencode "$CMD") && [[ ! "$resp" =~ "ERROR" ]]; then
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
            read -r -p "Имя для удаления: " cert_to_del
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
    # Собираем данные во временную переменную
    local status_info
    status_info=$(certbot certificates 2>/dev/null | grep -E "Certificate Name:|Expiry Date:" | sed 's/Expiry Date:/Истекает:/g' | awk '{$1=$1;print}')
    
    if [ -n "$status_info" ]; then
        # Читаем построчно и отправляем в log_msg
        while read -r line; do
            log_msg "   $line"
        done <<< "$status_info"
    else
        log_msg "   Сертификаты не найдены."
    fi
}

# --- ЗАПУСК ---
check_dependencies
rotate_log
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
    task_get_certs; task_install_to_cgp; task_show_status; send_notification
fi
