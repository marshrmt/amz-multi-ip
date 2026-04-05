# amz-multi-ip

One-shot installer для сервера с несколькими внешними IPv4, который поднимает:

- AmneziaWG 2.0 через `--proto awg`
- Xray VLESS Reality через `--proto xray`
- оба протокола сразу через `--proto both`

## Что умеет

- принимает список внешних IP аргументом
- работает через `curl | bash`
- поддерживает `awg`, `xray` и `both`
- для `xray` выбирает случайные порты в диапазоне `47000-49000`
- для нового `awg` резервирует случайный UDP-порт в диапазоне `47000-49000`
- не даёт `xray` и `awg` использовать один и тот же номер порта
- выводит готовые данные для импорта после установки

## Требования

- Ubuntu 24.04 / Ubuntu 22.04 / Debian 12+
- root-доступ
- VPS с несколькими реально маршрутизируемыми внешними IPv4
- открытые нужные порты в firewall/provider panel
- для импорта AWG 2.0 нужен достаточно новый клиент Amnezia

## Аргументы

- `--proto` - `awg`, `xray` или `both`
- `--ips` - список публичных IPv4 через запятую
- `--sni` - домен для Xray Reality
- `--prune` - удалить конфиги для IP, которых нет в текущем списке

## Быстрый старт

### Xray

```bash
curl -fsSL https://raw.githubusercontent.com/marshrmt/amz-multi-ip/main/install.sh | bash -s -- --proto xray --ips 203.0.113.11,203.0.113.12,203.0.113.13
```

### AWG

```bash
curl -fsSL https://raw.githubusercontent.com/marshrmt/amz-multi-ip/main/install.sh | bash -s -- --proto awg --ips 203.0.113.11,203.0.113.12,203.0.113.13
```

First install note:
- на чистом сервере upstream AWG installer требует 2 reboot
- одну и ту же команду нужно запустить 3 раза суммарно
- после каждого reboot просто снова выполните ту же команду

### Both

```bash
curl -fsSL https://raw.githubusercontent.com/marshrmt/amz-multi-ip/main/install.sh | bash -s -- --proto both --ips 203.0.113.11,203.0.113.12,203.0.113.13
```

First install note:
- на чистом сервере режим `both` тоже требует 2 reboot из-за AWG
- суммарно нужна 3-кратная повторная команда с теми же аргументами
- `xray` ставится на первом запуске
- итоговый полный вывод ссылок `xray` и `awg` будет на третьем запуске после второго reboot

## Вывод

- для `xray` скрипт печатает пары `ip` + `vless://...`
- для `awg` скрипт печатает пары `ip` + `vpn://...`
- для `both` скрипт печатает сначала секцию `[xray]`, затем секцию `[awg]`

## Vendored scripts

- внешний `Xray-install` зафиксирован в репо: [`vendor/xray-install/install-release.sh`](C:/universe/dev/amz-multi-ip/vendor/xray-install/install-release.sh)
- внешний `amneziawg-installer` зафиксирован в репо:
- [`vendor/amneziawg-installer/install_amneziawg_en.sh`](C:/universe/dev/amz-multi-ip/vendor/amneziawg-installer/install_amneziawg_en.sh)
- [`vendor/amneziawg-installer/awg_common_en.sh`](C:/universe/dev/amz-multi-ip/vendor/amneziawg-installer/awg_common_en.sh)
- [`vendor/amneziawg-installer/manage_amneziawg_en.sh`](C:/universe/dev/amz-multi-ip/vendor/amneziawg-installer/manage_amneziawg_en.sh)
- основной [`install.sh`](C:/universe/dev/amz-multi-ip/install.sh) скачивает эти скрипты уже через raw-ссылки этого репозитория
