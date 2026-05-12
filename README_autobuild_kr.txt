GCT Autobuild 설치/운영 가이드
===============================

현재 운영 구조 요약
-------------------
autobuild는 모델 라인업별로 아래 항목을 매일 실행합니다.

- GDM7275X
  - OpenWrt v1.00
  - OpenWrt master
  - Zephyros
  - Linuxos master
- GDM7243A
  - uTKernel - gdm7243a_no_l2
- GDM7243ST
  - uTKernel - gdm7243mt_32mb_no_l2_vport14
- GDM7243i
  - zephyr-v2.3 - gdm7243i_nbiot_ntn_quad

주요 스크립트:

- openwrt_autobuild.sh: OpenWrt 빌드 자동화
- zephyros_autobuild.sh: Zephyros 빌드 자동화
- os_autobuild.sh: 모델/OS 공용 빌드 자동화
- send_daily_autobuild_report.sh: 모델별 daily report mail 발송
- upload_daily_autobuild_logs.sh: daily log Samba 업로드
- run_daily_autobuild_test_once.sh: 정식 Daily flow와 동일한 1회성 전체 테스트 예약
- install_autobuild_cron.sh: 권장 cron 설치 명령
- install_openwrt_autobuild_cron.sh: 기존 호환용 cron 설치 명령

Daily report mail은 중앙 notifier가 담당합니다. 개별 build script에서
메일을 직접 발송하지 않습니다.

Daily build log와 성공한 빌드의 지정 산출물은 아래 Samba 네트워크 드라이브
기준으로 날짜별 업로드됩니다. 각 항목은 모델/빌드 항목별 하위 폴더 아래
Image와 Log로 구분됩니다.

K:\ENG\ENG05\CS\Test Log\Daily_build\YYYYMMDD

공통 설정은 Git repository 안의 config/*.env에 둡니다. 이렇게 하면 gct
계정에서 실행하든 jamesahn 계정에서 확인하든 git pull 이후 같은 설정으로
동작합니다. 공통 파일에는 SMTP, Samba 업로드 경로처럼 모든 빌드 항목이
공유하는 값을 정의합니다. 각 타겟별 env 파일은 공통 파일을 source한 뒤
repo, branch, build command, artifact 경로처럼 타겟별 값만 정의합니다.

Samba 계정/패스워드는 env 파일에 저장하지 않습니다. cron 설치 전에 Samba
share를 한 번 mount/login해야 하며, installer가 설정된 local upload
directory에 쓰기 가능한지 확인합니다.


이전 OpenWrt 중심 설치 가이드
==============================

이 문서는 같은 서버의 다른 계정에서도 OpenWrt v1.00 autobuild를
설치하고 운영할 수 있도록 절차를 정리한 가이드입니다.


준비할 파일
-----------
autobuild 스크립트는 Git으로 관리되는 아래 디렉터리에 둡니다.

- ~/gct-build-tools/autobuild/openwrt_autobuild.sh
- install_openwrt_autobuild_cron.sh
- zephyros_autobuild.sh
- send_daily_autobuild_report.sh

설정 파일은 repository 안에서 관리합니다.

- config/openwrt_v1.00_autobuild.env
- config/openwrt_master_autobuild.env
- config/zephyros_autobuild.env


1. Git 관리 디렉터리 준비
-------------------------
아직 GitHub에서 clone하지 않은 경우:

git clone <GCT_BUILD_TOOLS_REPO_URL> ~/gct-build-tools

이미 로컬에 파일이 있는 경우에는 아래 구조를 유지합니다.

~/gct-build-tools/autobuild


2. 실행 권한 확인
-----------------
chmod +x ~/gct-build-tools/autobuild/*.sh


3. repository config 확인
-------------------------
공용 env 파일은 아래 디렉터리에서 관리합니다.

~/gct-build-tools/autobuild/config

Daily build 설정 변경 시 이 디렉터리의 파일을 확인하고 수정합니다.


4. 필수 명령 확인
-----------------
which git
which python3
which expect


5. 먼저 수동 테스트 1회 실행
----------------------------
CONFIG_FILE=~/gct-build-tools/autobuild/config/openwrt_v1.00_autobuild.env ~/gct-build-tools/autobuild/openwrt_autobuild.sh

정식 Daily flow와 동일하게 5분 뒤부터 전체 항목을 1분 간격으로 예약하고
Noti mail 및 Samba 업로드까지 확인하려면 아래 1회성 테스트 스크립트를
사용합니다. 테스트 Noti mail은 기본적으로 jamesahn@gctsemi.com 에게만
발송됩니다.

~/gct-build-tools/autobuild/run_daily_autobuild_test_once.sh

실제 예약 없이 실행 계획만 확인하려면:

~/gct-build-tools/autobuild/run_daily_autobuild_test_once.sh --dry-run


6. 수동 테스트 결과 확인
------------------------
cat ~/gct_workspace/autobuild/logs/openwrt/v1.00/latest_status.txt
cat ~/gct_workspace/autobuild/logs/openwrt/v1.00/latest_summary.env


7. cron 등록
------------
~/gct-build-tools/autobuild/install_autobuild_cron.sh


8. cron 등록 확인
-----------------
crontab -l

정상 등록되면 아래와 비슷한 형식의 줄이 보입니다.

0 0 * * * CONFIG_FILE=/home/<user>/gct-build-tools/autobuild/config/openwrt_v1.00_autobuild.env /bin/bash -lc '/home/<user>/gct-build-tools/autobuild/openwrt_autobuild.sh >> "/home/<user>/gct_workspace/autobuild/logs/openwrt/v1.00/cron_runner.log" 2>&1' # OPENWRT_AUTOBUILD_V100


9. 야간 빌드 결과 확인
-----------------------
cat ~/gct_workspace/autobuild/logs/openwrt/v1.00/latest_status.txt
cat ~/gct_workspace/autobuild/logs/openwrt/v1.00/latest_summary.env
tail -n 100 ~/gct_workspace/autobuild/logs/openwrt/v1.00/cron_runner.log


중요 사항
---------
- autobuild 스크립트 파일들은 반드시 같은 디렉터리에 있어야 합니다.
- 스크립트 본체와 공용 env 파일은 ~/gct-build-tools/autobuild에서 Git으로 관리합니다.
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
