# Vendored upstream scripts

Этот каталог хранит snapshots внешних shell-скриптов, которые использует `install.sh`.

## Sources

- `vendor/xray-install/install-release.sh`
  upstream: `https://github.com/XTLS/Xray-install`
- `vendor/amneziawg-installer/install_amneziawg_en.sh`
  upstream: `https://github.com/bivlked/amneziawg-installer`
- `vendor/amneziawg-installer/awg_common_en.sh`
  upstream: `https://github.com/bivlked/amneziawg-installer`
- `vendor/amneziawg-installer/manage_amneziawg_en.sh`
  upstream: `https://github.com/bivlked/amneziawg-installer`

## Notes

- `vendor/amneziawg-installer/install_amneziawg_en.sh` пропатчен так, чтобы скачивать `awg_common_en.sh` и `manage_amneziawg_en.sh` уже из этого репозитория.
- Остальные vendored-файлы сохранены как upstream snapshots и обновляются вручную при необходимости.
