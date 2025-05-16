#!/bin/bash

# Настраиваемые переменные (замените на свои значения)
DOMAINS="domain1.ru domain2.ru domain3.ru"  # Список ваших доменов через пробел. Можно оставить только один.
POSTMASTER_NAME="your_email@domain.ru"      # Ваш email для авторизации (postmaster@domen.ru)
POSTMASTER_PASSWORD="your_password"         # Ваш пароль postmaster
NOTIFICATION_EMAIL="recipient_email@domain.ru"  # Email для уведомлений
IP_CGP_SERVER="127.0.0.1"              # IP сервера CommuniGate Pro (скорее всего 127.0.0.1)
CLI_PORT="8100"                    # Порт CLI (обычно 8100)
SMTP_SERVER="127.0.0.1:25"         # SMTP сервер и порт (например, 127.0.0.1:25)

# Остальные переменные
LOG_FILE="/var/log/update_cgp_cert.log"
SUCCESS_MESSAGES=()
ERROR_MESSAGES=()

echo "[$(date)]: Начало выполнения скрипта" >> "$LOG_FILE"

send_notification() {
    local temp_file="/tmp/cgp_email_$$.txt"
    local subject="Обновление сертификатов: Итоговый отчёт"
    local message=""
    local boundary="----=_Boundary_$(date +%s)"

    # Формируем текст сообщения
    if [ ${#SUCCESS_MESSAGES[@]} -gt 0 ]; then
        message+="Успешно обновлены сертификаты:\n"
        for msg in "${SUCCESS_MESSAGES[@]}"; do
            message+="- $msg\n"
        done
    fi
    if [ ${#ERROR_MESSAGES[@]} -gt 0 ]; then
        message+="\nОшибки при обновлении сертификатов:\n"
        for msg in "${ERROR_MESSAGES[@]}"; do
            message+="- $msg\n"
        done
    fi
    if [ ${#SUCCESS_MESSAGES[@]} -eq 0 ] && [ ${#ERROR_MESSAGES[@]} -eq 0 ]; then
        message="Ничего не обработано."
    fi

    # Создаём письмо с вложением в MIME-формате
    {
        echo "From: \"Admin\" <$POSTMASTER_NAME>"
        echo "To: $NOTIFICATION_EMAIL"
        echo "Subject: $subject"
        echo "Date: $(date -R)"
        echo "Message-ID: <$(date +%s)>"
        echo "MIME-Version: 1.0"
        echo "Content-Type: multipart/mixed; boundary=\"$boundary\""
        echo ""
        echo "--$boundary"
        echo "Content-Type: text/plain; charset=utf-8"
        echo "Content-Transfer-Encoding: 8bit"
        echo ""
        echo -e "$message"
        echo ""
        echo "--$boundary"
        echo "Content-Type: application/octet-stream; name=\"update_cgp_cert.log\""
        echo "Content-Transfer-Encoding: base64"
        echo "Content-Disposition: attachment; filename=\"update_cgp_cert.log\""
        echo ""
        base64 "$LOG_FILE"
        echo ""
        echo "--$boundary--"
    } > "$temp_file"

    # Логируем содержимое письма (без base64-данных для читаемости)
    echo "[$(date)]: Содержимое отправляемого письма (без вложения):" >> "$LOG_FILE"
    grep -v "$(base64 "$LOG_FILE" | head -n 1)" "$temp_file" >> "$LOG_FILE"

    # Отправляем письмо
    curl --url "smtp://$SMTP_SERVER" \
         --mail-from "$POSTMASTER_NAME" \
         --mail-rcpt "$NOTIFICATION_EMAIL" \
         --upload-file "$temp_file" >> "$LOG_FILE" 2>&1

    if [ $? -eq 0 ]; then
        echo "[$(date)]: Уведомление отправлено на $NOTIFICATION_EMAIL" >> "$LOG_FILE"
        # Удаляем лог-файл после успешной отправки
        rm -f "$LOG_FILE"
        echo "[$(date)]: Лог-файл $LOG_FILE удалён после отправки" > "$LOG_FILE"
    else
        echo "[$(date)]: Ошибка отправки уведомления на $NOTIFICATION_EMAIL" >> "$LOG_FILE"
    fi

    # Удаляем временный файл
    rm -f "$temp_file"
}

for DOMAIN_NAME in $DOMAINS; do
    echo "[$(date)]: Обработка домена $DOMAIN_NAME" >> "$LOG_FILE"
    CERT_PATH="/etc/letsencrypt/live/mail.$DOMAIN_NAME"
    LETS_ENCRYPT_KEY="$CERT_PATH/privkey.pem"
    LETS_ENCRYPT_CRT="$CERT_PATH/cert.pem"
    LETS_ENCRYPT_CHAIN_CRT="$CERT_PATH/fullchain.pem"

    if [ ! -f "$LETS_ENCRYPT_KEY" ] || [ ! -f "$LETS_ENCRYPT_CRT" ] || [ ! -f "$LETS_ENCRYPT_CHAIN_CRT" ]; then
        echo "[$(date)]: [ERROR]: Файлы сертификата для $DOMAIN_NAME не найдены!" >> "$LOG_FILE"
        ERROR_MESSAGES+=("Файлы сертификата для $DOMAIN_NAME не найдены.")
        continue
    fi

    echo "[$(date)]: Подготовка ключа для $DOMAIN_NAME" >> "$LOG_FILE"
    private_secure_key=$(openssl rsa -in "$LETS_ENCRYPT_KEY" -traditional 2> /dev/null | grep -v '\-\-' | tr -d '\n')
    echo "[$(date)]: Подготовка сертификата для $DOMAIN_NAME" >> "$LOG_FILE"
    secure_sertificate=$(cat "$LETS_ENCRYPT_CRT" | grep -v '\-\-' | tr -d '\n')
    echo "[$(date)]: Подготовка цепочки для $DOMAIN_NAME" >> "$LOG_FILE"
    le_chain_crt=$(cat "$LETS_ENCRYPT_CHAIN_CRT" | grep -v '\-\-' | tr -d '\n')

    # Формируем команду для одного запроса
    COMMAND="command=updatedomainsettings ${DOMAIN_NAME} {PrivateSecureKey=[${private_secure_key}];SecureCertificate=[${secure_sertificate}];CAChain=[${le_chain_crt}];}"

    # Отправляем всё одним запросом
    curl -u "$POSTMASTER_NAME:$POSTMASTER_PASSWORD" -k "http://$IP_CGP_SERVER:$CLI_PORT/cli/" \
         --data-urlencode "$COMMAND" >> "$LOG_FILE" 2>&1

    if [ $? -eq 0 ]; then
        echo "[$(date)]: Сертификаты для $DOMAIN_NAME успешно обновлены" >> "$LOG_FILE"
        SUCCESS_MESSAGES+=("Сертификат для $DOMAIN_NAME успешно обновлён и применён в CommuniGate Pro.")
    else
        echo "[$(date)]: [ERROR]: Не удалось обновить сертификаты для $DOMAIN_NAME" >> "$LOG_FILE"
        ERROR_MESSAGES+=("Не удалось обновить сертификаты для $DOMAIN_NAME.")
    fi
done

# Отправляем итоговое уведомление с вложением лога
send_notification

echo "[$(date)]: Завершение выполнения скрипта" >> "$LOG_FILE"
