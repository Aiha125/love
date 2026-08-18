#!/bin/bash
set -x
# -x : 실행되는 명령을 화면에 출력 (디버깅)

REGION="ap-northeast-2"
# 변수 정의. 등호(=) 양옆에 공백을 넣으면 안 됨. REGION = "..." 은 에러.

export AWS_DEFAULT_REGION="$REGION"
# export : 이 변수를 "환경변수"로 만들어 이 셸에서 실행되는 모든 자식 프로세스(aws 명령 포함)가 보게 함
# AWS_DEFAULT_REGION : aws CLI가 --region 없이도 이 리전을 쓰게 하는 표준 환경변수


# ─────────────────────────────────────────────
# 별칭(alias) 이름을 변수로 미리 정의
# ─────────────────────────────────────────────
KMS_S3_ALIAS="alias/wskorea26-s3-key"
KMS_ECR_ALIAS="alias/wskorea26-ecr-key"
KMS_DDB_ALIAS="alias/wskorea26-dynamodb-key"
KMS_EKS_ALIAS="alias/wskorea26-eks-key"
# KMS 키는 원래 UUID(a1b2c3d4-...) 로만 식별됨. 사람이 외우기 어려우므로
# "alias/이름" 형태의 별칭을 붙여서 부른다.
# 별칭은 반드시 alias/ 로 시작해야 함.
#
# 용도별로 키를 4개로 나눈 이유:
#   키 하나가 유출되어도 피해 범위를 그 서비스로 한정하기 위함 (최소 권한 원칙)


ensure_key() {
# ensure_key() { ... } : 함수 정의.
#   "이미 있으면 그대로 쓰고, 없으면 만든다"는 멱등(idempotent) 동작을 구현.
#   스크립트를 두 번 돌려도 키가 중복 생성되지 않게 하는 안전장치.

  local alias="$1" name="${1#alias/}"
  # local          : 이 변수를 함수 안에서만 유효하게 만듦 (바깥 변수와 충돌 방지)
  # "$1"           : 함수에 넘긴 첫 번째 인자 (예: alias/wskorea26-s3-key)
  # ${1#alias/}    : 문자열 앞부분에서 "alias/" 를 한 번 잘라냄
  #                  → wskorea26-s3-key 만 남음. 키 설명(description)에 쓸 용도.
  #                  # 은 "앞에서 최단 일치 삭제", ## 는 "앞에서 최장 일치 삭제"

  local keyid
  # 값을 나중에 넣을 빈 지역변수 선언

  keyid=$(aws kms list-aliases --query "Aliases[?AliasName=='${alias}'].TargetKeyId" --output text)
  # list-aliases  : 계정 안의 모든 KMS 별칭 목록을 가져옴
  # --query       : JMESPath로 필터링
  #   Aliases[?AliasName=='...']  : 별칭 이름이 정확히 일치하는 항목만 고름
  #   .TargetKeyId                : 그 별칭이 가리키는 실제 키 ID를 뽑음
  # 결과: 이미 있으면 키 ID 문자열, 없으면 빈 문자열

  if [ -z "$keyid" ] || [ "$keyid" = "None" ]; then
  # if [ ... ]  : 조건문. 대괄호 양옆에 반드시 공백이 있어야 함.
  # -z "$keyid" : 문자열 길이가 0이면 참 (= 키가 없음)
  # ||          : OR (둘 중 하나만 참이면 실행)
  # "None"      : aws CLI가 결과 없음을 None으로 출력하는 경우 대비
  # "$keyid" 처럼 따옴표로 감싸는 이유: 값이 비었을 때 문법 오류가 나지 않게 하려고

    keyid=$(aws kms create-key \
      --description "$name" \
      --tags TagKey=Name,TagValue=$name \
      --query 'KeyMetadata.KeyId' --output text)
    # create-key    : 새 대칭 KMS 키 생성 (기본값: 암호화/복호화용 대칭키)
    # --description : 콘솔에 표시될 설명문
    # --tags        : KMS만 문법이 특이함. Key=/Value= 가 아니라 TagKey=/TagValue= 를 씀.
    # KeyMetadata.KeyId : 생성 응답에서 키 ID만 추출

    aws kms create-alias --alias-name "$alias" --target-key-id "$keyid"
    # create-alias      : 방금 만든 키에 사람이 읽을 수 있는 별칭을 붙임
    # --target-key-id   : 별칭이 가리킬 실제 키
  fi
  # fi : if 문의 끝 (if를 거꾸로 쓴 것)

  local arn; arn=$(aws kms describe-key --key-id "$keyid" --query 'KeyMetadata.Arn' --output text)
  # 세미콜론(;) : 한 줄에 두 명령을 이어 쓸 때 사용
  # describe-key : 키의 상세 정보 조회
  # KeyMetadata.Arn : 전체 ARN
  #   (예: arn:aws:kms:ap-northeast-2:123456789012:key/uuid)
  #   S3·DynamoDB·EKS 설정에는 키 ID가 아니라 이 ARN이 필요한 경우가 많음

  echo "$arn"
  # 함수의 "반환값" 역할.
  # 쉘 함수는 값을 return 할 수 없고 종료코드(0~255)만 반환하므로,
  # echo로 표준출력에 찍고 호출부에서 $( ) 로 받아가는 방식을 씀.
}


S3_KEY_ARN=$(ensure_key "$KMS_S3_ALIAS");
ECR_KEY_ARN=$(ensure_key "$KMS_ECR_ALIAS");
DDB_KEY_ARN=$(ensure_key "$KMS_DDB_ALIAS");
EKS_KEY_ARN=$(ensure_key "$KMS_EKS_ALIAS");
# 함수를 4번 호출해 키 4개를 보장하고, 각 ARN을 변수에 담음.
# 주의: 이 변수들은 "이 스크립트가 끝나면 사라짐".
#       다음 스크립트(03~05)들은 그래서 매번
#       aws kms describe-key --key-id alias/... 로 ARN을 다시 조회한다.
#
# 줄 끝의 세미콜론(;)은 없어도 동작함. 있어도 무해.
