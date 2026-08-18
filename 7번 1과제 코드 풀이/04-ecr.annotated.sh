#!/bin/bash
set -x

export AWS_PAGER=""
# AWS_PAGER : aws CLI 출력이 길면 less 같은 페이저로 넘어가 "q를 눌러야 진행"되는 문제 발생.
#             빈 문자열로 두면 페이저를 쓰지 않고 그냥 전부 출력한다. 스크립트에서 필수.

export AWS_DEFAULT_REGION="$REGION"
# ⚠ 버그: 이 시점에 REGION 변수가 아직 정의되지 않았다(바로 아래 줄에서 정의됨).
#         결과적으로 AWS_DEFAULT_REGION="" 이 되어 리전이 비어버린다.
#         → 스크립트 실행 전에 직접 export AWS_DEFAULT_REGION=ap-northeast-2 를 해두거나,
#           이 줄을 REGION 정의 아래로 옮겨야 한다.

REGION="ap-northeast-2"
ECR_NAME="wskorea26-book-repo"      # 만들 ECR 리포지토리 이름
KMS_ALIAS="alias/wskorea26-ecr-key" # 이미지 암호화에 쓸 KMS 키 별칭
IMAGE_TAG="stable"                  # 이미지에 붙일 태그

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
# 화면에 색깔 있는 메시지를 찍는 도우미 함수.
# printf     : echo보다 형식 제어가 정확한 출력 명령
# \033[1;36m : ANSI escape. 1=굵게, 36=청록색
# \033[0m    : 색상 초기화 (안 하면 이후 출력이 계속 물듦)
# "$*"       : 함수에 넘긴 모든 인자를 하나의 문자열로 합침
# 참고: 이 스크립트에서는 실제로 호출되지 않는다(정의만 되어 있음).

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
# get-caller-identity : 지금 내가 누구인지 확인 (계정 ID / 사용자 ARN / UserId)
# Account             : 12자리 AWS 계정 번호. ECR 주소를 조립하는 데 필요.

KMS_ARN=$(aws kms describe-key --key-id "$KMS_ALIAS" --query 'KeyMetadata.Arn' --output text)
# 별칭으로 조회해 전체 ARN을 얻음. ECR 암호화 설정에는 ARN이 필요.

REPOSITORY_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_NAME}"
# ECR 주소의 고정 형식: <계정ID>.dkr.ecr.<리전>.amazonaws.com/<리포지토리명>
# ${변수} 처럼 중괄호를 쓰는 이유: 뒤에 붙는 문자(.dkr)와 변수명이 섞이지 않게 경계를 명확히 하려고


aws ecr create-repository \
    --repository-name "$ECR_NAME" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=KMS,kmsKey="$KMS_ARN" > /dev/null
# create-repository            : 컨테이너 이미지를 보관할 저장소 생성
# --image-scanning-configuration scanOnPush=true
#                              : 이미지를 푸시할 때마다 자동으로 취약점 스캔 (채점 항목)
# --encryption-configuration   : 저장 시 암호화 방식
#   encryptionType=KMS         : 기본 AES256 대신 내가 만든 KMS 키를 사용
#   kmsKey=<ARN>               : 사용할 키
# > /dev/null                  : 표준출력을 버림. /dev/null은 "쓰면 사라지는 특수 파일".
#                                긴 JSON 응답이 화면을 어지럽히지 않게 하는 용도.


cat <<EOF > Dockerfile
# 아래는 Dockerfile 내용. Dockerfile은 # 주석을 지원하므로 안전하게 설명을 달 수 있다.

FROM ubuntu:24.04
# FROM : 기반이 되는 베이스 이미지. Ubuntu 24.04 LTS 위에 쌓아 올린다.

RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*
# RUN                     : 이미지를 만드는 도중 실행할 명령
# apt-get update          : 패키지 목록 갱신
# apt-get upgrade -y      : 설치된 패키지를 최신으로 (보안 취약점 스캔 점수를 위해)
#   -y                    : 모든 확인 질문에 자동으로 yes
# --no-install-recommends : 권장 패키지는 빼고 꼭 필요한 것만 → 이미지 크기 감소
# ca-certificates         : HTTPS 통신에 필요한 루트 인증서 (없으면 AWS API 호출 실패)
# rm -rf /var/lib/apt/lists/* : 패키지 목록 캐시 삭제 → 이미지 용량 절감
# && 로 이어 붙인 이유    : RUN 한 줄 = 이미지 레이어 한 개.
#                           나눠 쓰면 삭제한 캐시가 이전 레이어에 남아 용량이 안 줄어든다.
# 줄 끝 \                 : 다음 줄과 이어진 한 줄이라는 표시

WORKDIR /app
# WORKDIR : 이후 명령의 기준 디렉터리. 없으면 자동 생성된다.

COPY --chmod=755 ./book ./book
# COPY          : 빌드 컨텍스트(현재 폴더)의 파일을 이미지 안으로 복사
# --chmod=755   : 복사하면서 실행 권한 부여 (7=소유자 rwx, 5=그룹 r-x, 5=기타 r-x)
#                 이게 없으면 "Permission denied"로 컨테이너가 뜨지 않는다.
# ./book        : 왼쪽=내 PC의 파일, 오른쪽=이미지 안의 경로(/app/book)

ENV AWS_REGION="ap-northeast-2"
ENV TABLE_NAME="wskorea26-data-table"
# ENV : 컨테이너 실행 시 적용될 환경변수.
#       Go 앱(book)이 이 값을 읽어 DynamoDB에 접속한다.

EXPOSE 8080
# EXPOSE : "이 컨테이너는 8080 포트를 쓴다"는 문서화용 선언.
#          실제 포트를 여는 건 아니고, 쿠버네티스 Service가 참고할 정보.

CMD ["./book"]
# CMD : 컨테이너가 시작될 때 실행할 기본 명령.
#       대괄호 형식(exec form)을 쓰면 셸을 거치지 않아 종료 신호가 앱에 바로 전달된다.
EOF


aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
# get-login-password : ECR 접속용 임시 비밀번호(12시간 유효 토큰)를 출력
# |                  : 그 값을 docker login으로 바로 넘김
# --username AWS     : ECR은 사용자명이 항상 고정 문자열 "AWS"
# --password-stdin   : 비밀번호를 표준입력으로 받음.
#                      명령줄 인자로 쓰면 셸 히스토리에 비밀번호가 남으므로 이 방식이 안전.

docker build -t "${ECR_NAME}:${IMAGE_TAG}" .
# build : Dockerfile을 읽어 이미지를 만듦
# -t    : 태그(이름) 지정. 형식은 이름:태그
# .     : 빌드 컨텍스트 = 현재 디렉터리.
#         여기 있는 파일만 COPY 할 수 있으므로 book 파일이 같은 폴더에 있어야 한다.

docker tag "${ECR_NAME}:${IMAGE_TAG}" "${REPOSITORY_URI}:${IMAGE_TAG}"
# tag : 같은 이미지에 이름을 하나 더 붙임(복사가 아니라 별명).
#       ECR에 올리려면 이름이 반드시 ECR 주소로 시작해야 하기 때문에 필요한 단계.

docker push "${REPOSITORY_URI}:${IMAGE_TAG}"
# push : 이미지를 ECR로 업로드.
#        ⏱ 3~5분. 업로드가 끝나고 1~2분 뒤에야 취약점 스캔 결과가 조회된다.
