OpenWrt Autobuild 설치/운영 가이드
===================================

이 문서는 같은 서버의 다른 계정에서도 OpenWrt v1.00 autobuild를
설치하고 운영할 수 있도록 절차를 정리한 가이드입니다.


준비할 파일
-----------
autobuild 스크립트는 Git으로 관리되는 아래 디렉터리에 둡니다.

- ~/gct-build-tools/autobuild/openwrt_autobuild.sh
- install_openwrt_autobuild_cron.sh
- zephyros_autobuild.sh
- send_daily_autobuild_report.sh

설정 예시는 필요 시 별도로 관리합니다.

- ~/.config/openwrt_v1.00_autobuild.env
- ~/.config/openwrt_master_autobuild.env
- ~/.config/zephyros_autobuild.env


1. Git 관리 디렉터리 준비
-------------------------
아직 GitHub에서 clone하지 않은 경우:

git clone <GCT_BUILD_TOOLS_REPO_URL> ~/gct-build-tools

이미 로컬에 파일이 있는 경우에는 아래 구조를 유지합니다.

~/gct-build-tools/autobuild


2. 기존 실행 경로 연결
----------------------
기존처럼 ~/autobuild 경로로 실행할 수 있도록 symlink를 만듭니다.

ln -sfn ~/gct-build-tools/autobuild ~/autobuild


3. 실행 권한 확인
-----------------
chmod +x ~/gct-build-tools/autobuild/*.sh


4. 설정 파일 생성
-----------------
mkdir -p ~/.config

아래 파일을 생성합니다.

~/.config/openwrt_v1.00_autobuild.env

권장 내용:

OPENWRT_BRANCH=v1.00
PKG_VERSION=0.0.0


5. 필수 명령 확인
-----------------
which git
which python3
which expect


6. 먼저 수동 테스트 1회 실행
----------------------------
CONFIG_FILE=~/.config/openwrt_v1.00_autobuild.env ~/autobuild/openwrt_autobuild.sh


7. 수동 테스트 결과 확인
------------------------
cat ~/gct_workspace/autobuild/logs/openwrt/v1.00/latest_status.txt
cat ~/gct_workspace/autobuild/logs/openwrt/v1.00/latest_summary.env


8. cron 등록
------------
~/autobuild/install_openwrt_autobuild_cron.sh


9. cron 등록 확인
-----------------
crontab -l

정상 등록되면 아래와 비슷한 형식의 줄이 보입니다.

0 0 * * * CONFIG_FILE=/home/<user>/.config/openwrt_v1.00_autobuild.env /bin/bash -lc '/home/<user>/autobuild/openwrt_autobuild.sh >> "/home/<user>/gct_workspace/autobuild/logs/openwrt/v1.00/cron_runner.log" 2>&1' # OPENWRT_AUTOBUILD_V100


10. 야간 빌드 결과 확인
-----------------------
cat ~/gct_workspace/autobuild/logs/openwrt/v1.00/latest_status.txt
cat ~/gct_workspace/autobuild/logs/openwrt/v1.00/latest_summary.env
tail -n 100 ~/gct_workspace/autobuild/logs/openwrt/v1.00/cron_runner.log


중요 사항
---------
- autobuild 스크립트 파일들은 반드시 같은 디렉터리에 있어야 합니다.
- 스크립트 본체는 ~/gct-build-tools/autobuild에서 Git으로 관리하고, 계정별 설정은 ~/.config/*.env에 둡니다.
- cron 등록 전에 반드시 수동 테스트를 먼저 수행하는 것을 권장합니다.
- 사용 계정이 필요한 저장소 접근 권한을 가지고 있어야 합니다.
- 빌드 로그는 아래 경로에 저장됩니다.
  ~/gct_workspace/autobuild/logs/openwrt/v1.00
- autobuild 작업 디렉터리는 아래 경로에 생성됩니다.
  ~/gct_workspace/autobuild/repos/openwrt/builds/v1.00
- autobuild용 repository clone은 아래 경로에 생성됩니다.
  ~/gct_workspace/autobuild/repos/openwrt/deps


빌드 후 자주 확인하는 파일
---------------------------
- 최신 상태:
  ~/gct_workspace/autobuild/logs/openwrt/v1.00/latest_status.txt
- 최신 요약:
  ~/gct_workspace/autobuild/logs/openwrt/v1.00/latest_summary.env
- cron 실행 로그:
  ~/gct_workspace/autobuild/logs/openwrt/v1.00/cron_runner.log
- 개별 실행 로그 디렉터리:
  ~/gct_workspace/autobuild/logs/openwrt/v1.00/YYYYMMDD_HHMMSS


현재 계정에서 autobuild 삭제 방법
---------------------------------
현재 계정에 설치된 autobuild를 제거할 때는 아래 순서를 권장합니다.


1. cron 등록 제거
-----------------
현재 cron 등록 상태 확인:

crontab -l

필요하면 직접 수정:

crontab -e

또는 자동으로 제거:

tmp=$(mktemp)
crontab -l 2>/dev/null | grep -Ev 'OPENWRT_V100_AUTOBUILD|OPENWRT_AUTOBUILD_V100' > "$tmp" || true
crontab "$tmp"
rm -f "$tmp"


2. 실행 중인 autobuild 프로세스 확인
------------------------------------
ps -ef | egrep 'openwrt_autobuild.sh|gct_workspace/autobuild/repos/openwrt/builds/v1.00|openwrt_dirty_build_.*_autobuild.exp' | grep -v egrep

아무것도 보이지 않으면 다음 단계로 진행합니다.


3. autobuild 관련 파일/디렉터리 삭제
------------------------------------
rm -f ~/autobuild
rm -f ~/.config/openwrt_v1.00_autobuild.env
rm -rf ~/gct_workspace/autobuild/repos/openwrt/builds/v1.00
rm -rf ~/gct_workspace/autobuild/repos/openwrt/deps
rm -rf ~/gct_workspace/autobuild/logs/openwrt/v1.00
rm -rf ~/gct_workspace/autobuild/tmp/openwrt_${USER}_v1.00


4. 최종 확인
------------
cron 엔트리가 삭제되었는지 확인:

crontab -l | grep OPENWRT_AUTOBUILD_V100

관련 디렉터리가 삭제되었는지 확인:

ls -ld ~/gct_workspace/autobuild/repos/openwrt/builds/v1.00 ~/gct_workspace/autobuild/repos/openwrt/deps ~/gct_workspace/autobuild/logs/openwrt/v1.00 2>/dev/null


삭제 시 주의사항
----------------
- ~/gct_workspace/autobuild 전체를 지우기보다 필요한 대상 경로만 지우는 것을 권장합니다.
- ~/gct_workspace/autobuild/repos/openwrt/deps는 autobuild 전용일 때만 삭제하는 것이 안전합니다.
- ~/gct_workspace/autobuild/repos/openwrt/builds/v1.00는 autobuild용 작업 디렉터리일 때만 삭제하는 것이 안전합니다.
