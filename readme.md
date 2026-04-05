# amz-multi-ip

One-shot installer для сервера с **несколькими внешними IPv4**, который поднимает:

- **AmneziaWG 2.0** (`--proto awg`)
- **Xray VLESS Reality** (`--proto xray`)

Сценарий использования:
- у тебя **один VPS**
- у VPS **несколько внешних IP**
- скрипт создаёт **по одному конфигу на каждый IP**
- дальше ты **импортируешь эти конфиги в Amnezia VPN**

## Что умеет

- принимает список внешних IP аргументом
- работает через `curl | bash`
- поддерживает выбор протокола:
  - `awg`
  - `xray`
- для `xray` автоматически генерирует случайный порт в диапазоне **47000–49000**
- для `xray` по умолчанию использует:
  - `SNI = video.yahoo.com`
- выводит готовые данные для импорта после установки

## Требования

- Ubuntu 24.04 / Ubuntu 22.04 / Debian 12+
- root-доступ
- VPS с несколькими **реально маршрутизируемыми** внешними IPv4
- открытые нужные порты в firewall/provider panel
- для импорта **AWG 2.0** нужен достаточно новый клиент Amnezia

## Аргументы

- `--proto` — `awg` или `xray`
- `--ips` — список публичных IPv4 через запятую
- `--sni` — домен для Xray Reality, по умолчанию `video.yahoo.com`

## Быстрый старт

### Xray

```bash
curl -fsSL https://raw.githubusercontent.com/marshrmt/amz-multi-ip/refs/heads/main/install.sh | bash -s -- --proto xray --ips 203.0.113.11,203.0.113.12,203.0.113.13