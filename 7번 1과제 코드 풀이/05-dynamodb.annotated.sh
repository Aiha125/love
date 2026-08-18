#!/bin/bash
set -x

export AWS_PAGER=""      # 페이저 비활성화 (04번 설명 참고)
REGION="ap-northeast-2"

DDB_KEY_ARN=$(aws kms describe-key --key-id alias/wskorea26-dynamodb-key --region $REGION --query 'KeyMetadata.Arn' --output text)
# DynamoDB 테이블 암호화에 쓸 KMS 키 ARN을 별칭으로 조회


# ─────────────────────────────────────────────
# 테이블 생성
# ─────────────────────────────────────────────
aws dynamodb create-table \
    --table-name wskorea26-data-table \
    --attribute-definitions AttributeName=client_id,AttributeType=S \
    --key-schema AttributeName=client_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --deletion-protection-enabled \
    --sse-specification Enabled=true,SSEType=KMS,KMSMasterKeyId=$DDB_KEY_ARN \
    --region $REGION
# --table-name            : 테이블 이름
# --attribute-definitions : "키로 사용할 속성"만 미리 선언한다.
#                           DynamoDB는 스키마가 없어서 나머지 컬럼은 선언할 필요가 없음.
#   AttributeType=S       : S=String, N=Number, B=Binary
# --key-schema            : 기본 키 구성
#   KeyType=HASH          : 파티션 키(=기본 키). 데이터가 저장될 물리적 위치를 결정.
#                           RANGE(정렬 키)를 추가하면 복합 키가 된다.
# --billing-mode PAY_PER_REQUEST
#                         : 온디맨드 과금. 요청 수만큼만 지불하고 용량을 미리 잡지 않음.
#                           (반대는 PROVISIONED = 읽기/쓰기 용량을 미리 예약)
# --deletion-protection-enabled
#                         : 실수로 테이블을 지우지 못하게 잠금 (채점 항목)
# --sse-specification     : 저장 시 암호화 설정
#   Enabled=true          : 암호화 켬
#   SSEType=KMS           : AWS 기본 키가 아니라 고객 관리형 KMS 키 사용
#   KMSMasterKeyId=<ARN>  : 사용할 키
#
# ⏱ 테이블이 ACTIVE가 되기까지 10~30초. 아래 describe-table이 바로 성공하지 않을 수 있다.


TABLE_ARN=$(aws dynamodb describe-table \
    --table-name wskorea26-data-table \
    --region $REGION \
    --query 'Table.TableArn' --output text)
# 방금 만든 테이블의 ARN을 조회.
# IAM 정책에서 "이 테이블만 허용"이라고 자원을 특정하려면 ARN이 필요하다.

KMS_KEY_ARN=$(aws kms describe-key \
    --key-id alias/wskorea26-dynamodb-key \
    --region $REGION \
    --query 'KeyMetadata.Arn' --output text)
# 위의 DDB_KEY_ARN과 사실 같은 값. 아래 정책 문서에서 쓰려고 다시 담은 것.


# ─────────────────────────────────────────────
# Lambda용 IAM 권한 정책 (읽기 전용)
# ─────────────────────────────────────────────
# ⚠ 아래 블록은 JSON이다. JSON에는 주석 문법이 없으므로 안에 # 을 넣으면 파싱이 깨진다.
#   그래서 각 항목 설명을 여기에 먼저 적어둔다.
#
#   "Version"   : 정책 언어 버전. "2012-10-17"이 사실상 고정값(최신).
#   "Statement" : 권한 규칙들의 배열. 각 규칙은 아래 요소로 구성된다.
#   "Sid"       : Statement ID. 사람이 알아보기 위한 이름표. 동작에 영향 없음.
#   "Effect"    : Allow(허용) 또는 Deny(거부)
#   "Action"    : 허용할 API 동작 목록
#     dynamodb:GetItem  : 키로 항목 1개 조회
#     dynamodb:Scan     : 테이블 전체를 훑어 읽기 (lambda.py가 이걸 사용)
#     kms:Decrypt       : 암호화된 데이터를 복호화. 이게 없으면 읽어도 내용을 못 봄.
#     kms:DescribeKey   : 키 정보 조회 (SDK가 내부적으로 호출)
#     kms:GenerateDataKey / GenerateDataKeyWithoutPlaintext
#                       : 데이터 키 생성. 쓰기 작업에 쓰이며, 읽기만 할 땐 없어도 되지만
#                         SDK 동작을 넉넉히 잡아두려고 포함한 것.
#   "Resource"  : 이 권한이 적용될 대상. "*"(전체)가 아니라 특정 ARN으로 좁혀
#                 최소 권한 원칙을 지키고 있다.
cat <<EOF > lambda-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "DynamoDBGetItemPermission",
            "Effect": "Allow",
            "Action": [
                "dynamodb:GetItem",
                "dynamodb:Scan"
            ],
            "Resource": "$TABLE_ARN"
        },
        {
            "Sid": "KMSDecryptPermission",
            "Effect": "Allow",
            "Action": [
                "kms:Decrypt",
                "kms:DescribeKey",
                "kms:GenerateDataKey",
                "kms:GenerateDataKeyWithoutPlaintext"
            ],
            "Resource": "$KMS_KEY_ARN"
        }
    ]
}
EOF


# ─────────────────────────────────────────────
# 신뢰 정책 (누가 이 역할을 빌려 쓸 수 있는가)
# ─────────────────────────────────────────────
# 위의 "권한 정책"이 '무엇을 할 수 있는가'라면,
# 아래 "신뢰 정책(trust policy)"은 '누가 이 역할이 될 수 있는가'를 정한다.
#   "Principal": { "Service": "lambda.amazonaws.com" }
#       → Lambda 서비스가 이 역할을 대신 맡을 수 있다는 뜻.
#         이게 없으면 Lambda 함수 생성 시 "역할을 assume 할 수 없다"는 오류가 난다.
#   "Action": "sts:AssumeRole"
#       → 역할을 빌리는 동작 자체의 이름.
cat <<EOF > lambda-trust-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "lambda.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF


POLICY_ARN=$(aws iam create-policy \
    --policy-name wskorea26-book-lambda-policy \
    --policy-document file://lambda-policy.json \
    --query 'Policy.Arn' --output text)
# create-policy     : 재사용 가능한 "관리형 정책"을 계정에 등록
# --policy-document file://경로
#                   : 파일 내용을 읽어 넣으라는 표기.
#                     file:// 를 빼면 "lambda-policy.json"이라는 문자열 자체를 정책으로 해석해 실패한다.
# Policy.Arn        : 다음 단계에서 역할에 붙일 때 필요

aws iam create-role \
    --role-name wskorea26-book-lambda-role \
    --assume-role-policy-document file://lambda-trust-policy.json
# create-role                  : IAM 역할 생성
# --assume-role-policy-document: 신뢰 정책. 역할 생성 시 반드시 함께 지정해야 한다.
#                                (권한 정책은 역할을 만든 뒤 따로 붙인다)

aws iam attach-role-policy \
    --role-name wskorea26-book-lambda-role \
    --policy-arn $POLICY_ARN
# attach-role-policy : 위에서 만든 권한 정책을 역할에 연결.
#                      이제 이 역할은 "Lambda가 맡을 수 있고, DynamoDB를 읽을 수 있는" 상태가 된다.

rm lambda-policy.json lambda-trust-policy.json
# rm : 임시로 만든 JSON 파일 삭제. 이미 AWS에 등록됐으므로 로컬 파일은 필요 없다.
#
# 이 스크립트가 만든 역할 이름(wskorea26-book-lambda-role)을
# Lambda 함수 생성 시 실행 역할로 지정하면 된다.
