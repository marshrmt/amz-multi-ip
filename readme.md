
### Xray

```bash
curl -fsSL https://raw.githubusercontent.com/marshrmt/amz-multi-ip/main/install.sh | bash -s -- --proto xray --ips 203.0.113.11,203.0.113.12,203.0.113.13
```

- IP вводить без пробелов между запятыми
- Vless ссылку можно скопировать в Амнезию или v2rayn клиент

### AWG

```bash
curl -fsSL https://raw.githubusercontent.com/marshrmt/amz-multi-ip/main/install.sh | bash -s -- --proto awg --ips 203.0.113.11,203.0.113.12,203.0.113.13
```

- IP вводить без пробелов между запятыми
- на чистом сервере upstream AWG installer требует 2 ребута
- одну и ту же команду нужно запустить 3 раза суммарно
- после каждого reboot просто снова выполните ту же команду

### Both (сразу оба)

```bash
curl -fsSL https://raw.githubusercontent.com/marshrmt/amz-multi-ip/main/install.sh | bash -s -- --proto both --ips 203.0.113.11,203.0.113.12,203.0.113.13
```

- IP вводить без пробелов между запятыми
- на чистом сервере upstream AWG installer требует 2 ребута
- одну и ту же команду нужно запустить 3 раза суммарно
- после каждого reboot просто снова выполните ту же команду

## Вывод

- для `xray` скрипт печатает пары `ip` + `vless://...`
- для `awg` скрипт печатает пары `ip` + `vpn://...`
- для `both` скрипт печатает сначала секцию `[xray]`, затем секцию `[awg]`
