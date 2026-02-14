# backlight_brightness_ble_controller

A Flutter pet-project for control BLE LED-strip from dependencies of desktop display backlight level

## Headless Arch quick launch

```bash
sudo bash deploy/launch_product.sh
```

After launch, open local console from LAN:

- `http://backlight.local` (or your configured `LOCAL_DASHBOARD_NAME`)

## Release builds via GitHub Actions

Builds for **Android, Linux, and Windows** run automatically when you push a tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

## Product roadmap

The current product roadmap and implementation checklist are tracked in:

- `docs/PRODUCT_ROADMAP.md`
- `docs/FREE_INFRA_AND_AUTH.md`
- `docs/ARCH_SERVER_RUNBOOK.md`
- `docs/BACKEND_GATEWAY_API.md`
- `docs/MONETIZATION_AND_PRIVACY.md`
- `docs/IMPLEMENTATION_STATUS.md`

## Application Icon

For regenerate application icon, run:

```shell
flutter pub run flutter_launcher_icons
```
