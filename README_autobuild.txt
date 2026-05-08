GCT Autobuild Setup Guide
=========================

Current Operation Summary
-------------------------
The daily autobuild is organized by model lineup:

- GDM7275X
  - OpenWrt v1.00
  - OpenWrt master
  - Zephyros
  - Linuxos master build
- GDM7243A
  - uTKernel - gdm7243a_no_l2
- GDM7243ST
  - uTKernel - gdm7243mt_32mb_no_l2_vport14
- GDM7243i
  - zephyr-v2.3 - gdm7243i_nbiot_ntn_quad

Main scripts:

- openwrt_autobuild.sh: OpenWrt build automation
- zephyros_autobuild.sh: Zephyros build automation
- os_autobuild.sh: generic model/OS build automation
- send_daily_autobuild_report.sh: model-grouped daily mail notifier
- upload_daily_autobuild_logs.sh: daily log upload to Samba
- install_autobuild_cron.sh: preferred cron installer
- install_openwrt_autobuild_cron.sh: backward-compatible cron installer

Daily report mail is handled by the central notifier. Individual build scripts
do not send daily mail directly.

Daily build logs are uploaded to the mapped Windows drive path:

K:\ENG\ENG05\CS\Test Log\Daily_build\YYYYMMDD

Account-specific settings belong in ~/.config/*.env and must not be committed.
Use 600 permissions because the env files can contain mail credentials.


Legacy OpenWrt-Focused Setup Guide
==================================

This guide explains how to install and run the OpenWrt v1.00 autobuild
scripts under another account on the same server.

Files to prepare
----------------
Keep the autobuild scripts in this Git-managed directory:

- ~/gct-build-tools/autobuild/openwrt_autobuild.sh
- install_openwrt_autobuild_cron.sh
- zephyros_autobuild.sh
- send_daily_autobuild_report.sh

Config examples can be managed separately when needed:

- ~/.config/openwrt_v1.00_autobuild.env
- ~/.config/openwrt_master_autobuild.env
- ~/.config/zephyros_autobuild.env


1. Prepare the Git-managed directory
------------------------------------
If the repository is not cloned yet:

git clone <GCT_BUILD_TOOLS_REPO_URL> ~/gct-build-tools

If the files already exist locally, keep this directory layout:

~/gct-build-tools/autobuild


2. Check execute permissions
----------------------------
chmod +x ~/gct-build-tools/autobuild/*.sh


3. Create the config file
-------------------------
mkdir -p ~/.config

Create this file:

~/.config/openwrt_v1.00_autobuild.env

Recommended contents:

OPENWRT_BRANCH=v1.00
PKG_VERSION=0.0.0


4. Check required commands
--------------------------
which git
which python3
which expect


5. Run one manual test first
----------------------------
CONFIG_FILE=~/.config/openwrt_v1.00_autobuild.env ~/gct-build-tools/autobuild/openwrt_autobuild.sh


6. Check the manual test result
-------------------------------
cat ~/gct_workspace/autobuild/logs/openwrt/v1.00/latest_status.txt
cat ~/gct_workspace/autobuild/logs/openwrt/v1.00/latest_summary.env


7. Register the daily cron job
------------------------------
~/gct-build-tools/autobuild/install_autobuild_cron.sh


8. Verify cron registration
---------------------------
crontab -l

Expected cron entry format:

0 0 * * * CONFIG_FILE=/home/<user>/.config/openwrt_v1.00_autobuild.env /bin/bash -lc '/home/<user>/gct-build-tools/autobuild/openwrt_autobuild.sh >> "/home/<user>/gct_workspace/autobuild/logs/openwrt/v1.00/cron_runner.log" 2>&1' # OPENWRT_AUTOBUILD_V100


9. Check nightly build results
-------------------------------
cat ~/gct_workspace/autobuild/logs/openwrt/v1.00/latest_status.txt
cat ~/gct_workspace/autobuild/logs/openwrt/v1.00/latest_summary.env
tail -n 100 ~/gct_workspace/autobuild/logs/openwrt/v1.00/cron_runner.log


Important notes
---------------
- The autobuild script files must stay in the same directory.
- Manage script files under ~/gct-build-tools/autobuild and keep account-specific settings in ~/.config/*.env.
- Run the manual test before enabling cron.
- The account must have access to the required repositories.
- The build logs are written under:
  ~/gct_workspace/autobuild/logs/openwrt/v1.00
- The autobuild work tree is created under:
  ~/gct_workspace/autobuild/repos/openwrt/builds/v1.00
- Repository clones for autobuild are created under:
  ~/gct_workspace/autobuild/repos/openwrt/deps


Useful files after a build
--------------------------
- Latest status:
  ~/gct_workspace/autobuild/logs/openwrt/v1.00/latest_status.txt
- Latest summary:
  ~/gct_workspace/autobuild/logs/openwrt/v1.00/latest_summary.env
- Cron execution log:
  ~/gct_workspace/autobuild/logs/openwrt/v1.00/cron_runner.log
- Per-run build directory:
  ~/gct_workspace/autobuild/logs/openwrt/v1.00/YYYYMMDD_HHMMSS


Remove autobuild from the current account
-----------------------------------------
Use the following order when removing the autobuild setup.

1. Remove the cron entry
------------------------
Check the current cron entries:

crontab -l

If needed, remove the autobuild entry manually:

crontab -e

Or remove it automatically:

tmp=$(mktemp)
crontab -l 2>/dev/null | grep -Ev 'OPENWRT_V100_AUTOBUILD|OPENWRT_AUTOBUILD_V100' > "$tmp" || true
crontab "$tmp"
rm -f "$tmp"


2. Check for running autobuild processes
----------------------------------------
ps -ef | egrep 'openwrt_autobuild.sh|gct_workspace/autobuild/repos/openwrt/builds/v1.00|openwrt_dirty_build_.*_autobuild.exp' | grep -v egrep

If nothing is shown, continue to the next step.


3. Remove autobuild files and directories
-----------------------------------------
rm -f ~/.config/openwrt_v1.00_autobuild.env
rm -rf ~/gct_workspace/autobuild/repos/openwrt/builds/v1.00
rm -rf ~/gct_workspace/autobuild/repos/openwrt/deps
rm -rf ~/gct_workspace/autobuild/logs/openwrt/v1.00
rm -rf ~/gct_workspace/autobuild/tmp/openwrt_${USER}_v1.00


4. Final checks
---------------
Check that the cron entry is gone:

crontab -l | grep OPENWRT_AUTOBUILD_V100

Check that the autobuild paths are gone:

ls -ld ~/gct_workspace/autobuild/repos/openwrt/builds/v1.00 ~/gct_workspace/autobuild/repos/openwrt/deps ~/gct_workspace/autobuild/logs/openwrt/v1.00 2>/dev/null


Removal notes
-------------
- Do not remove ~/gct_workspace/autobuild entirely. Remove only the target-specific paths you no longer need.
- Remove ~/gct_workspace/autobuild/repos/openwrt/deps only if it is used only for autobuild.
- Remove ~/gct_workspace/autobuild/repos/openwrt/builds/v1.00 only if it is the autobuild work tree.
