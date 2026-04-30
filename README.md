# GCT Autobuild Scripts

Cron-oriented autobuild scripts for OpenWrt, Zephyros, and daily build report notification.

## Layout

```text
openwrt_autobuild.sh
zephyros_autobuild.sh
install_openwrt_autobuild_cron.sh
send_daily_autobuild_report.sh
README_autobuild_kr.txt
README_autobuild.txt
```

## Install

Clone this repository under `~/gct-build-tools/autobuild`, then keep the legacy run path as a symlink:

```bash
ln -sfn ~/gct-build-tools/autobuild ~/autobuild
chmod +x ~/gct-build-tools/autobuild/*.sh
```

Account-specific settings belong in `~/.config/*.env`, not in this repository.

See `README_autobuild_kr.txt` for the Korean operation guide.
