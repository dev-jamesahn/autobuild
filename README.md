# GCT Autobuild Scripts

Cron-oriented autobuild scripts for model-line build verification.

## Current Lineup

```text
GDM7275X
- OpenWrt v1.00
- OpenWrt master
- Zephyros
- Linuxos master

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
run_daily_autobuild_test_once.sh   One-time full Daily flow test scheduler
install_autobuild_cron.sh         Preferred cron installer
install_openwrt_autobuild_cron.sh Backward-compatible cron installer
```

## Install

Keep the repository under `~/gct-build-tools/autobuild` and install cron from that real path:

```bash
chmod +x ~/gct-build-tools/autobuild/*.sh
~/gct-build-tools/autobuild/install_autobuild_cron.sh
```

Account-specific settings belong in `~/.config/*.env`, not in this repository.

Daily build logs are written under `~/gct_workspace/autobuild/logs`. Logs and
selected artifacts from successful builds are uploaded to:

```text
K:\ENG\ENG05\CS\Test Log\Daily_build\YYYYMMDD
```

Each build item is uploaded below a model/build directory split into `Image`
and `Log` subdirectories.

## One-Time Full Daily Test

To run the same flow as the Daily cron without changing the registered cron
table, schedule one-time jobs from the operating account:

```bash
~/gct-build-tools/autobuild/run_daily_autobuild_test_once.sh
```

The helper schedules the seven build jobs with the same 1-minute stagger as
Daily cron starting 5 minutes later, then schedules notifier attempts every 10
minutes. The notifier uses the existing report mail and Samba upload logic, but
the one-time test mail is sent only to `jamesahn@gctsemi.com` by default. Use
`--dry-run` to review the jobs without scheduling them.

See `README_autobuild_kr.txt` for the Korean operation guide.
