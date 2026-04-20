
# CommuniGate Pro SSL Master

Bash-скрипт для автоматизации получения и установки SSL-сертификатов Let's Encrypt для почтового сервера CommuniGate Pro.
Bash script for automating the receipt and installation of Let's Encrypt SSL certificates for the CommuniGate Pro mail server.

## Возможности
* **Автоматическое обнаружение доменов**: Скрипт запрашивает список доменов напрямую у CGP через CLI.
* **Умное управление портами**: Автоматически останавливает веб-сервисы (Nginx, Caddy, Apache), занимающие 80 порт, на время проверки Certbot и запускает их обратно.
* **Инжекция через CLI**: Сертификаты устанавливаются напрямую в настройки доменов CGP (PrivateSecureKey, SecureCertificate, CAChain) без перезагрузки сервера.
* **Двойной режим**:
    * *Интерактивный*: Удобное меню для ручного управления.
    * *Фоновый*: Работа через systemd-таймер с отправкой HTML-отчетов на почту.
* **Очистка**: Удаление просроченных сертификатов из системы.

## Требования
* ОС: Linux (Debian/Ubuntu/CentOS)
* Установленные пакеты: `certbot`, `curl`, `lsof`, `openssl`
* Доступ к CommuniGate Pro по протоколам CLI (8100) и SMTP (25).

## Установка

## Включить использование CLI для локального адреса

Settings\Srvices\HTTPU прокрутить ниже до **Доп. протоколы** параметр **CLI** установить clients.

**Settings\Network\Client IPs** Указать 127.0.0.1 как клиентский адрес. 

Включить PKI Services
Settings\Domain\<NameDomain>\Security\SSL/TLS параметр PKI Services установить в Enabled.


### 1. Копируем скрипт к себе
```
 wget https://raw.githubusercontent.com/saym101/update_cgp_cert/refs/heads/main/update_cgp_cert.sh
```

### 2. Отредактируйте блок настроек в начале файла `update_cgp_cert.sh`:
   * `EMAIL_ADMIN`: Логин администратора CGP.
   * `SMTP_PASS`: Пароль администратора.
   * `EMAIL_REPORT`: Ваш адрес для получения отчетов.

### 3. Дайте права на выполнение:
   ```bash
   chmod +x update_cgp_cert.sh
   ```

## Настройка автоматизации (systemd)

Для автоматического обновления сертификатов каждые 30 дней создайте service и timer:

**1. /etc/systemd/system/update_cgp_cert.service**
```ini
[Unit]
Description=Update CommuniGate Pro SSL Certificates
After=network.target

[Service]
Type=oneshot
ExecStart=/путь/к/скрипту/update_cgp_cert.sh
```

**2. /etc/systemd/system/update_cgp_cert.timer**
```ini
[Unit]
Description=Run update_cgp_cert every day

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
Unit=update_cgp_cert.service

[Install]
WantedBy=timers.target
```

Активируйте таймер:
```bash
systemctl daemon-reload
systemctl enable --now update_cgp_cert.timer
```
## 🔒 Безопасность
- **Не храните пароль в коде!** Лучше использовать переменные окружения или хранить пароль в защищённом файле.
- Убедитесь, что **`postmaster` имеет доступ к API CommuniGate Pro**.

## Лицензия
MIT
```
