# Обновление сертификатов в CommuniGate Pro

Этот скрипт автоматически обновляет SSL-сертификаты для нескольких доменов в сервере **CommuniGate Pro** (CGP) с использованием сертификатов **Let's Encrypt**. Также он отправляет уведомления с логами обновления на email.

## 📌 Функциональность
- Обновляет **ключ, сертификат и цепочку сертификатов** для указанных доменов в CGP.
- Логирует процесс обновления в `/var/log/update_cgp_cert.log`.
- **Автоматически отправляет email-уведомления** с итогами работы.
- Работает с несколькими доменами одновременно.
- Может быть добавлен в `cron` для автоматического обновления сертификатов.

## 🔧 Установка и использование

## Включить использование CLI для локального адреса

Settings\Srvices\HTTPU прокрутить ниже до **Доп. протоколы** параметр **CLI** установить clients.

Указать 127.0.0.1 как клиентский адрес. **Settings\Network\Client IPs** 

Включить PKI Services
Settings\Domain\<NameDomain>\Security\SSL/TLS параметр PKI Services установить в Enabled.

### 1. Копируем скрипт к себе
```
 wget https://github.com/saym101/update_cgp_cert/raw/refs/heads/main/update_cgp_cert.sh
```

### 2. Настройка переменных
Перед использованием необходимо отредактировать переменные в скрипте:
```bash
DOMAINS=("stpserver.ru talabsk.ru zaweru.ru")  # Укажите свои домены
POSTMASTER_NAME="postmaster@stpserver.ru"
POSTMASTER_PASSWORD="Brqada123!"  # Укажите свой пароль
NOTIFICATION_EMAIL="postmaster@stpserver.ru"
IP_CGP_SERVER="127.0.0.1"
CLI_PORT="8100"
SMTP_SERVER="127.0.0.1:25"
```

### 3. Даем права на выполнение
```bash
chmod +x update_cgp_cert.sh
```

### 4. Запуск скрипта вручную
```bash
./update_cgp_cert.sh
```

### 5. Автоматический запуск раз в 60 дней через systemd
Создайте service-файл /etc/systemd/system/update_cgp_cert.service:
```bash
[Unit]
Description=Update CommuniGate Pro SSL Certificates
After=network.target

[Service]
Type=oneshot
ExecStart=/path/to/update_cgp_cert.sh
```
Создайте timer-файл /etc/systemd/system/update_cgp_cert.timer:
```bash
[Unit]
Description=Run update_cgp_cert.sh every 60 days

[Timer]
OnBootSec=5min
OnUnitInactiveSec=6912000  # 80 дней в секундах
Unit=update_cgp_cert.service

[Install]
WantedBy=timers.target
```
Активируйте таймер:
```bash
systemctl daemon-reload
systemctl enable --now update_cgp_cert.timer
```

## 📜 Логи и отладка
После выполнения скрипта лог-файл можно найти здесь:
```bash
cat /var/log/update_cgp_cert.log
```

## 🔒 Безопасность
- **Не храните пароль в коде!** Лучше использовать переменные окружения или хранить пароль в защищённом файле.
- Убедитесь, что **`postmaster` имеет доступ к API CommuniGate Pro**.

## 🎯 TODO
- [ ] Автоматическое обновление сертификатов через `certbot`
- [ ] Поддержка HTTPS-запросов для API CommuniGate Pro
- [ ] Лог каждый раз новый после выполнения скрипта

---

📌 Автор: [Александр](https://github.com/saym101) | 🚀 [GitHub Repo](https://github.com/saym101/update_cgp_cert)

