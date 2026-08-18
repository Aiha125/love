#!/bin/bash
set -x

curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
# eksctl 재설치. 03번에서 이미 깔았다면 그냥 덮어쓰는 것이라 무해하다.
# (세션이 바뀌어 /usr/local/bin이 초기화된 경우를 대비한 방어 코드)

CLUSTER_NAME="wskorea26-cluster"
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)


# ═════════════════════════════════════════════
# 1) AWS Load Balancer Controller 설치
#    쿠버네티스 Ingress 오브젝트를 보고 실제 ALB를 만들어주는 컨트롤러
# ═════════════════════════════════════════════
ROLE_NAME="${CLUSTER_NAME}-LBControllerRole"
POLICY_NAME="${CLUSTER_NAME}-LBControllerPolicy"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

CLUSTER_OIDC=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text | sed 's/https:\/\///')
# cluster.identity.oidc.issuer : 클러스터의 OIDC 발급자 URL
#   (예: https://oidc.eks.ap-northeast-2.amazonaws.com/id/ABCD1234)
# sed 's/찾을것/바꿀것/'        : 문자열 치환 도구
#   's/https:\/\///'           : "https://" 를 빈 문자열로 바꿔 제거.
#                                슬래시(/)가 sed의 구분자와 겹치므로 \/ 로 이스케이프함.
# 왜 제거하나 : IAM 신뢰 정책에는 스킴(https://) 없이 도메인만 넣어야 하기 때문.

# ⚠ 아래 --assume-role-policy-document 는 JSON 문자열이라 안에 주석을 못 넣는다.
#   구조 설명:
#     "Principal": { "Federated": "arn:aws:iam::<계정>:oidc-provider/<OIDC>" }
#         → 이 클러스터의 OIDC 공급자가 발급한 토큰을 신뢰하겠다는 뜻
#     "Action": "sts:AssumeRoleWithWebIdentity"
#         → 웹 아이덴티티(=쿠버네티스 서비스어카운트 토큰)로 역할을 빌리는 동작
#     "Condition" 의 두 줄이 핵심 보안 장치다:
#         ":aud": "sts.amazonaws.com"
#             → 토큰의 수신 대상이 STS여야 함
#         ":sub": "system:serviceaccount:kube-system:aws-load-balancer-controller"
#             → 정확히 이 네임스페이스의 이 서비스어카운트만 허용.
#               없으면 클러스터의 아무 파드나 이 역할을 빌릴 수 있게 된다.
#   따옴표 '"$ACCOUNT_ID"' 표기:
#         작은따옴표로 감싼 JSON 안에서 잠시 빠져나와 변수를 넣고 다시 들어가는 기법.
#         '...'"$VAR"'...' 형태로, 변수만 큰따옴표 구간에 놓는다.
aws iam create-role \
    --role-name $ROLE_NAME \
    --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {
                    "Federated": "arn:aws:iam::'"$ACCOUNT_ID"':oidc-provider/'"$CLUSTER_OIDC"'"
                },
                "Action": "sts:AssumeRoleWithWebIdentity",
                "Condition": {
                    "StringEquals": {
                        "'"$CLUSTER_OIDC"':aud": "sts.amazonaws.com",
                        "'"$CLUSTER_OIDC"':sub": "system:serviceaccount:kube-system:aws-load-balancer-controller"
                    }
                }
            }
        ]
    }' \
    --output json

curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
# -O : URL의 파일명 그대로 현재 폴더에 저장 (소문자 -o 는 이름을 직접 지정)
# 이 JSON은 컨트롤러가 ALB·타겟그룹·보안그룹을 다루는 데 필요한 권한 목록. 공식 제공본이다.

POLICY_ARN=$(aws iam create-policy \
    --policy-name $POLICY_NAME \
    --policy-document file://iam_policy.json \
    --query 'Policy.Arn' --output text)

aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn $POLICY_ARN
# 역할에 권한 정책 연결

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cat <<EOF >> service-account.yaml
# ⚠ >> 는 "덧붙이기(append)". 파일이 이미 있으면 내용이 계속 쌓여 YAML이 깨진다.
#    재실행 전에는 rm -f service-account.yaml 을 해야 안전하다. (> 였다면 덮어쓰기)
apiVersion: v1
kind: ServiceAccount            # 파드가 사용할 쿠버네티스 계정
metadata:
  labels:                       # 라벨은 분류/검색용 메타데이터
    app.kubernetes.io/component: controller
    app.kubernetes.io/name: aws-load-balancer-controller
  name: aws-load-balancer-controller
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}
    # 이 어노테이션이 IRSA의 핵심.
    # 이 서비스어카운트를 쓰는 파드에게 위 IAM 역할의 임시 자격증명이 자동 주입된다.
    # 덕분에 액세스 키를 파드에 심을 필요가 없다.
EOF

kubectl apply -f service-account.yaml
# apply : 매니페스트를 클러스터에 적용. 없으면 생성, 있으면 갱신(선언형).

rm iam_policy.json
rm service-account.yaml

curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3
# -f : HTTP 오류 시 에러코드 반환 (실패한 HTML을 파일로 저장하는 사고 방지)
# -s : 조용히
# -S : -s와 함께 쓸 때 에러 메시지만은 보여줌
# -L : 리다이렉트 따라가기
# -o : 저장할 파일명 지정

chmod +x get_helm.sh    # 실행 권한 부여
./get_helm.sh           # Helm 설치 (Helm = 쿠버네티스용 패키지 관리자)

helm repo add eks https://aws.github.io/eks-charts
# repo add : 차트 저장소 등록. eks 는 내가 붙인 별칭.

helm repo update
# 등록된 저장소의 차트 목록을 최신화

rm -f get_helm.sh
# -f : 파일이 없어도 에러를 내지 않음

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
# helm install <릴리스이름> <저장소/차트>
# -n kube-system              : 설치할 네임스페이스
# --set                       : 차트 기본값(values.yaml)을 명령줄에서 덮어씀
#   clusterName               : 컨트롤러가 관리할 클러스터. 틀리면 ALB가 안 만들어진다.
#   serviceAccount.create=false : 차트가 SA를 새로 만들지 말라는 뜻
#                                 (위에서 IAM 역할이 붙은 SA를 이미 만들었으므로)
#   serviceAccount.name       : 그 기존 SA를 쓰라고 지정
# ⏱ 파드가 Ready 되기까지 1~2분


# ═════════════════════════════════════════════
# 2) 네임스페이스
# ═════════════════════════════════════════════
NAMESPACE="wskorea26"
kubectl create ns $NAMESPACE
# ns = namespace의 축약형. 리소스를 논리적으로 격리하는 단위.
# ⚠ 이미 있으면 에러가 난다. 아래쪽에 나오는 --dry-run 방식이 더 안전하다.


# ═════════════════════════════════════════════
# 3) 앱 파드용 서비스어카운트 (DynamoDB 쓰기 권한)
# ═════════════════════════════════════════════
REGION="ap-northeast-2"
CLUSTER_NAME="wskorea26-cluster"
SA_NAME="wsc-sa"

TABLE_ARN=$(aws dynamodb describe-table --table-name wskorea26-data-table --region $REGION --query 'Table.TableArn' --output text)
KMS_KEY_ARN=$(aws kms describe-key --key-id alias/wskorea26-dynamodb-key --region $REGION --query 'KeyMetadata.Arn' --output text)

# ⚠ 아래는 JSON이라 내부 주석 불가. 구조 설명:
#   Lambda가 "읽기"였다면 앱 파드는 "쓰기" 권한을 갖는다. 역할을 나눠 최소 권한을 지킨 것.
#     dynamodb:PutItem       : 항목 저장 (예매 데이터 쓰기)
#     dynamodb:DescribeTable : 테이블 메타 정보 조회. SDK 초기화 시 필요.
#     kms:GenerateDataKey*   : 데이터를 암호화해 저장하려면 데이터 키를 만들어야 하므로 필수.
#                              (쓰기인데 Decrypt도 넣은 건 SDK 내부 동작 여유분)
cat <<EOF > wsc-sa-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "DynamoDBPutItemPermission",
            "Effect": "Allow",
            "Action": [
              "dynamodb:PutItem",
              "dynamodb:DescribeTable"
            ],
            "Resource": "$TABLE_ARN"
        },
        {
            "Sid": "KMSKeyPermissionForPut",
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

POLICY_ARN=$(aws iam create-policy \
  --policy-name wskorea26-book-sa-policy \
  --policy-document file://wsc-sa-policy.json \
  --query 'Policy.Arn' --output text)

kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
# --dry-run=client : 실제로 만들지 않고 만들어질 결과만 계산
# -o yaml          : 그 결과를 YAML로 출력
# | kubectl apply -f -
#   -f -           : 파일 대신 "표준입력"에서 읽으라는 뜻(하이픈이 stdin을 의미)
# 이 조합은 "있으면 그대로, 없으면 생성"을 만드는 관용구.
# 위쪽의 kubectl create ns 와 달리 두 번 실행해도 에러가 안 난다.

eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --name=$SA_NAME \
  --namespace=$NAMESPACE \
  --attach-policy-arn=$POLICY_ARN \
  --approve \
  --override-existing-serviceaccounts
# iamserviceaccount : IAM 역할 + 쿠버네티스 SA + 둘의 연결(IRSA)을 한 번에 처리
# --attach-policy-arn : 역할에 붙일 권한 정책
# --approve           : 확인 프롬프트 없이 바로 실행
# --override-existing-serviceaccounts : 같은 이름의 SA가 이미 있으면 덮어씀
# ⏱ 내부적으로 CloudFormation 스택을 만들어 2~3분 걸린다.

rm wsc-sa-policy.json


# ═════════════════════════════════════════════
# 4) 애플리케이션 배포 매니페스트
# ═════════════════════════════════════════════
REGION="ap-northeast-2"
REPO_NAME="wskorea26-book-repo" 
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}:stable"
# 04번에서 푸시한 이미지의 전체 주소

cat <<EOF > deployment.yaml
apiVersion: apps/v1
kind: Deployment                 # 파드를 원하는 개수만큼 유지·교체해주는 컨트롤러
metadata:
  name: book-deploy
  namespace: wskorea26
  labels:
    app: book
spec:
  replicas: 2                    # 파드를 항상 2개 유지
  selector:
    matchLabels:
      app: book                  # 이 라벨을 가진 파드를 내 소유로 인식
  template:                      # 아래는 만들어낼 파드의 설계도
    metadata:
      labels:
        app: book                # 위 selector와 반드시 일치해야 함
    spec:
      tolerations:
      - key: "node-type"
        operator: "Equal"
        value: "app"
        effect: "NoSchedule"
        # toleration : 03번에서 앱 노드에 건 taint를 "견디겠다"는 선언.
        #              이게 없으면 앱 노드에 절대 배치되지 않는다.
      nodeSelector:
        node-type: app  
        # nodeSelector : 이 라벨을 가진 노드에만 배치.
        # taint(못 들어옴) + toleration(견딤) + nodeSelector(가고 싶음)
        # 세 개가 모두 맞아야 앱 노드에 정확히 뜬다.
      serviceAccountName: wsc-sa
        # 위에서 만든 IRSA 서비스어카운트 사용 → 파드가 DynamoDB 쓰기 권한을 얻음
      containers:
        - name: book-ctn
          image: $IMAGE_URI
          ports:
          - containerPort: 8080  # 컨테이너가 리슨하는 포트
          resources:
            limits:
              cpu: 500m          # 상한. m = milli, 500m = 0.5 vCPU
                                 # 넘으면 스로틀링(속도 제한)됨
            requests:
              cpu: 200m          # 스케줄러가 자리를 잡을 때 기준으로 삼는 예약량
EOF

cat <<EOF >> service.yaml
# ⚠ 여기도 >> (덧붙이기)라 재실행 시 내용이 중복된다. 사전에 rm -f service.yaml 권장.
apiVersion: v1
kind: Service                    # 파드들 앞에 붙는 고정 진입점(가상 IP + DNS 이름)
metadata:
  name: book-svc
  namespace: wskorea26
spec:
  selector:
    app: book                    # 이 라벨을 가진 파드로 트래픽을 보냄
  ports:
  - port: 80                     # 서비스가 노출하는 포트
    targetPort: 8080             # 실제 컨테이너 포트로 전달
    protocol: TCP
  type: NodePort
    # NodePort : 각 노드의 포트를 열어 외부에서 접근 가능하게 함.
    #            ALB Ingress와 함께 쓸 때 흔히 쓰는 타입.
EOF


# ═════════════════════════════════════════════
# 5) Lambda를 ALB의 타겟으로 등록
# ═════════════════════════════════════════════
LAMBDA_ARN=$(aws lambda get-function --function-name wskorea26-book-lambda --query "Configuration.FunctionArn" --output text)
# ⚠ Lambda 함수가 미리 만들어져 있어야 한다. 없으면 여기서 실패한다.

TG_ARN=$(aws elbv2 create-target-group --name wskorea26-lambda-tg --target-type lambda --query "TargetGroups[0].TargetGroupArn" --output text)
# create-target-group  : ALB가 트래픽을 보낼 대상 묶음 생성
# --target-type lambda : 대상이 EC2/IP가 아니라 Lambda 함수임
#                        (이 타입은 포트·프로토콜을 지정하지 않는다)

aws lambda add-permission --function-name wskorea26-book-lambda --statement-id AllowALBInvoke --action lambda:InvokeFunction --principal elasticloadbalancing.amazonaws.com --source-arn $TG_ARN
# add-permission  : Lambda의 "리소스 기반 정책"에 규칙 추가
# --statement-id  : 이 규칙의 고유 이름 (중복 불가)
# --action lambda:InvokeFunction : 함수를 호출하는 권한
# --principal elasticloadbalancing.amazonaws.com : ELB 서비스에게 허용
# --source-arn    : 그중에서도 이 타겟그룹에서 오는 호출만 허용 (범위 제한)
# 이 권한이 없으면 다음 줄의 register-targets가 실패한다.

aws elbv2 register-targets --target-group-arn $TG_ARN --targets Id=$LAMBDA_ARN
# 타겟그룹에 Lambda 함수를 실제로 등록

PUB_SUBNET_C=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=wskorea26-pub-subnet-c" --region $REGION --query "Subnets[0].SubnetId" --output text)
PUB_SUBNET_D=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=wskorea26-pub-subnet-d" --region $REGION --query "Subnets[0].SubnetId" --output text)
# ALB를 놓을 퍼블릭 서브넷 ID 조회


# ═════════════════════════════════════════════
# 6) Ingress = ALB 설계도
# ═════════════════════════════════════════════
cat <<EOF > ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: book-ingress
  namespace: wskorea26
  annotations:
  # 어노테이션 : AWS Load Balancer Controller에게 주는 상세 지시사항.
  #              alb.ingress.kubernetes.io/ 로 시작하는 것이 모두 그 규약이다.
    alb.ingress.kubernetes.io/load-balancer-name: wskorea26-book-alb
      # 만들 ALB의 이름
    alb.ingress.kubernetes.io/scheme: internet-facing
      # internet-facing = 인터넷에서 접근 가능 / internal = VPC 내부 전용
    alb.ingress.kubernetes.io/subnets: $PUB_SUBNET_C, $PUB_SUBNET_D
      # ALB를 배치할 서브넷. 최소 2개 AZ가 필요하다.
    alb.ingress.kubernetes.io/target-type: ip
      # ip   = 파드 IP로 직접 전달 (빠름, VPC CNI 사용 시 권장)
      # instance = 노드의 NodePort를 거쳐 전달 (한 단계 더 돈다)
    alb.ingress.kubernetes.io/healthcheck-path: /health
      # ALB가 주기적으로 찔러보는 경로. 200이 안 오면 트래픽을 안 보낸다.
    alb.ingress.kubernetes.io/conditions.book-svc: '[{"field":"http-header","httpHeaderConfig":{"httpHeaderName":"X-Origin-Verify","values":["wskorea26-cf"]}}, {"field":"http-request-method","httpRequestMethodConfig":{"values":["POST"]}}]'
      # conditions.<서비스이름> : 그 규칙이 적용될 조건.
      #   ① X-Origin-Verify 헤더 값이 wskorea26-cf 여야 하고  (= CloudFront를 거쳐온 요청)
      #   ② HTTP 메서드가 POST 여야 함                        (= 예매 등록 요청)
      # 조건이 여럿이면 AND로 묶인다.
      # 헤더 검사가 있어야 ALB로 직접 들어오는 요청을 막을 수 있다.
    alb.ingress.kubernetes.io/conditions.reserv-lambda: '[{"field":"http-header","httpHeaderConfig":{"httpHeaderName":"X-Origin-Verify","values":["wskorea26-cf"]}}, {"field":"http-request-method","httpRequestMethodConfig":{"values":["GET"]}}]'
      # 같은 /book 경로라도 GET이면 Lambda로 보낸다. (조회 요청)
    alb.ingress.kubernetes.io/transforms.book-svc: '[{"type":"url-rewrite","urlRewriteConfig":{"rewrites":[{"regex":"^/book","replace":"/v1/book"}]}}]'
      # transforms : 백엔드로 넘기기 전에 URL을 고쳐 씀
      # ^/book → /v1/book   (^ 는 정규식에서 "문자열 시작")
      # 사용자에겐 /book으로 보이고 앱은 /v1/book으로 받는다.
    alb.ingress.kubernetes.io/transforms.reserv-lambda: '[{"type":"url-rewrite","urlRewriteConfig":{"rewrites":[{"regex":"^/book","replace":"/reserv-query"}]}}]'
    alb.ingress.kubernetes.io/actions.reserv-lambda: '{"type":"forward","forwardConfig":{"targetGroups":[{"targetGroupArn":"$TG_ARN","weight":1}]}}'
      # actions.<이름> : 쿠버네티스 서비스가 아닌 대상으로 보낼 때 쓰는 가상 백엔드 정의.
      #   type: forward     : 지정한 타겟그룹으로 전달
      #   targetGroupArn    : 위에서 만든 Lambda 타겟그룹
      #   weight: 1         : 가중치(여러 타겟그룹에 나눠 보낼 때 비율)
    alb.ingress.kubernetes.io/actions.response-403: '{"type":"fixed-response","fixedResponseConfig":{"contentType":"text/plain","statusCode":"403","messageBody":"Forbidden"}}'
      # fixed-response : 백엔드로 보내지 않고 ALB가 직접 고정 응답을 반환
      # 어떤 규칙에도 안 걸린 요청(=헤더 없는 직접 접근)에 403을 돌려주는 용도
spec:
  ingressClassName: alb
    # 이 Ingress를 AWS Load Balancer Controller가 처리하라는 지정
  defaultBackend:
    service:
      name: response-403
      port:
        name: use-annotation
        # use-annotation : "이 이름은 실제 서비스가 아니라 위 actions.<이름> 을 보라"는 약속.
        #                  즉 기본 동작 = 403 응답.
  rules:
  - http:
      paths:
      - path: /book
        pathType: Prefix        # Prefix = /book 으로 시작하는 모든 경로
        backend:
          service:
            name: book-svc      # POST 조건에 걸리면 여기(앱 파드)로
            port:
              number: 80
      - path: /book
        pathType: Prefix
        backend:
          service:
            name: reserv-lambda # GET 조건에 걸리면 여기(Lambda)로
            port:
              name: use-annotation
      # 같은 경로가 두 번 나오는 이유:
      #   경로는 같고 조건(메서드)만 다른 규칙 2개를 만들기 위함.
      #   위에서부터 순서대로 평가된다.
EOF

kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f ingress.yaml
# 세 매니페스트를 순서대로 적용.
# ⏱ Ingress 적용 후 ALB가 실제로 만들어지고 타겟이 healthy가 되기까지 3~5분.
#    kubectl get ingress -n wskorea26 -w 로 ADDRESS가 채워지는지 지켜보면 된다.
