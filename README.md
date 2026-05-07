# GCT Autobuild Scripts

Cron-oriented autobuild scripts for model-line build verification.

## Current Lineup

```text
GDM7275X
- OpenWrt v1.00
- OpenWrt master
- Zephyros

GDM7243A
- uTKernel - gdm7243a_no_l2

GDM7243ST
- uTKernel - gdm7243mt_32mb_no_l2_vport14

GDM7243i
- zephyr-v2.3 - gdm7243i_nbiot_ntn_quad
```

## Main Scripts

```text
openwrt_autobuild.sh              OpenWrt build automation
zephyros_autobuild.sh             Zephyros build automation
os_autobuild.sh                   Generic OS/model build automation
send_daily_autobuild_report.sh    Daily model-grouped mail notifier
upload_daily_autobuild_logs.sh    Daily log upload to Samba
install_autobuild_cron.sh         Preferred cron installer alias
install_openwrt_autobuild_cron.sh Backward-compatible cron installer
archive/                          Retired one-time test helpers
```

## Install

Keep the repository under `~/gct-build-tools/autobuild` and expose the legacy run path:

```bash
ln -sfn ~/gct-build-tools/autobuild ~/autobuild
chmod +x ~/gct-build-tools/autobuild/*.sh
~/autobuild/install_autobuild_cron.sh
```

Account-specific settings belong in `~/.config/*.env`, not in this repository.

Daily build logs are written under `~/gct_workspace/autobuild/logs` and uploaded to:

```text
K:\ENG\ENG05\CS\Test Log\Daily_build\YYYYMMDD
```

See `README_autobuild_kr.txt` for the Korean operation guide.
