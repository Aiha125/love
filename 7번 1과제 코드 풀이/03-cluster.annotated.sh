#!/bin/bash
set -x

EKS_KEY_ARN=$(aws kms describe-key --key-id alias/wskorea26-eks-key --query 'KeyMetadata.Arn' --output text)
# 02-kms.sh에서 만든 EKS용 키의 ARN을 별칭으로 다시 조회.
# 앞 스크립트의 변수는 사라졌으므로 매번 이렇게 재조회한다.

PRIV_SUBNET_C=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=wskorea26-priv-subnet-c" --query "Subnets[0].SubnetId" --output text)
PRIV_SUBNET_D=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=wskorea26-priv-subnet-d" --query "Subnets[0].SubnetId" --output text)
# describe-subnets : 서브넷 조회
# --filters        : 서버 쪽에서 걸러줌 (--query는 받아온 뒤 클라이언트에서 거름)
#   Name=tag:Name  : "Name 태그"로 검색하겠다는 의미
#   Values=...     : 찾을 태그 값
# Subnets[0]       : 결과 배열의 첫 번째 항목 (이름이 유일하므로 하나만 나옴)


cat <<EOF > cluster.yaml
# cat <<EOF > 파일명 : "히어독(heredoc)". EOF가 나올 때까지의 내용을 파일로 저장.
# EOF에 따옴표를 안 붙였으므로 안의 $변수가 실제 값으로 치환됨.
#   (cat <<'EOF' 처럼 작은따옴표를 붙이면 $가 그대로 남음)
# 아래는 YAML이라 # 주석을 넣어도 안전하다.

apiVersion: eksctl.io/v1alpha5   # eksctl 설정 파일의 스키마 버전
kind: ClusterConfig              # 이 문서의 종류: 클러스터 설정

metadata:
  name: wskorea26-cluster        # 클러스터 이름. 이후 모든 명령에서 이 이름을 씀
  version: "1.35"                # 쿠버네티스 버전. 따옴표 없으면 1.35가 숫자로 읽혀 오류 가능
  region: ap-northeast-2         # 생성 리전

secretsEncryption:
  keyARN: $EKS_KEY_ARN
  # 쿠버네티스 Secret 오브젝트를 etcd에 저장할 때 이 KMS 키로 한 번 더 암호화.
  # "봉투 암호화(envelope encryption)"라고 부름. 채점 항목이기도 함.

cloudWatch:
  clusterLogging:
    enableTypes: ["*"]
    # 컨트롤 플레인 로그를 CloudWatch로 전송.
    # "*" = 전체 5종 (api, audit, authenticator, controllerManager, scheduler)

iam:
  withOIDC: true
  # OIDC 공급자를 생성. 이게 있어야 IRSA(파드에 IAM 역할 부여)를 쓸 수 있음.
  # 없으면 아래 serviceAccounts 설정과 06번의 iamserviceaccount가 전부 실패한다.

  serviceAccounts:
  - metadata:
      name: aws-load-balancer-controller   # 만들 서비스어카운트 이름
      namespace: kube-system               # 만들 네임스페이스
    wellKnownPolicies:
      awsLoadBalancerController: true
      # eksctl이 미리 준비해둔 표준 IAM 정책 묶음을 자동으로 붙여줌.
      # 직접 정책 JSON을 만들 필요가 없어짐.
  - metadata:
      name: cert-manager
      namespace: cert-manager
    wellKnownPolicies:
      certManager: true                    # 인증서 자동 발급용 표준 정책

vpc:
  subnets:
    private:
      ap-northeast-2c: { id: $PRIV_SUBNET_C }
      ap-northeast-2d: { id: $PRIV_SUBNET_D }
      # 01번에서 만든 기존 서브넷을 재사용하겠다는 선언.
      # 이 항목이 없으면 eksctl이 VPC를 새로 만들어 버린다.
      # { id: ... } 는 YAML의 인라인 맵 표기 (여러 줄로 써도 동일)

managedNodeGroups:
# managedNodeGroups : AWS가 수명주기를 관리해주는 노드 그룹.
#                     (직접 관리하는 self-managed 방식과 구분)

  - name: wskorea26-app-ng          # 노드그룹 이름
    instanceName: wskorea26-app-node # EC2 인스턴스의 Name 태그
    instanceType: t3.medium          # 인스턴스 타입 (vCPU 2, 메모리 4GiB)
    tags:
      Name: wskorea26-app-node       # 노드그룹 리소스에 붙는 태그
    desiredCapacity: 2               # 지금 띄울 개수
    minSize: 2                       # 최소 개수 (이 아래로는 안 줄어듦)
    maxSize: 20                      # 최대 개수 (오토스케일 상한)
    privateNetworking: true          # 프라이빗 서브넷에 배치 = 공인 IP 없음
    labels: 
      node-type: app
      # 노드에 붙는 쿠버네티스 라벨.
      # 파드의 nodeSelector가 이 라벨을 보고 배치될 노드를 고른다.
    taints:
      - key: node-type
        value: app
        effect: NoSchedule
        # taint(오염) : "이 노드는 아무나 못 들어온다"는 표시.
        # NoSchedule  : 대응하는 toleration이 없는 파드는 여기 스케줄되지 않음.
        # 목적: 앱 노드에 모니터링 같은 부가 파드가 섞이지 않게 자리를 비워둠.
        # → 06번 deployment.yaml에 tolerations를 넣어야 앱 파드가 여기 뜬다.

  - name: wskorea26-addon-ng
    instanceName: wskorea26-addon-node
    tags:
      Name: wskorea26-addon-node
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 2
    maxSize: 20
    privateNetworking: true
    labels: 
      node-type: addon
      # 애드온 노드에는 taint가 없다.
      # → CoreDNS·LB Controller·Prometheus 등 일반 파드가 자연스럽게 이쪽으로 몰림.
      #   (앱 노드는 taint 때문에 못 들어가므로)
EOF
# 여기까지가 cluster.yaml 파일 내용


curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
# curl        : URL에서 파일을 내려받는 도구
# --silent    : 진행률 표시를 끔 (-s 와 동일)
# --location  : 리다이렉트를 따라감 (-L 와 동일). GitHub 릴리스는 리다이렉트가 걸려 있어 필수.
# $(uname -s) : OS 이름을 출력 (리눅스면 Linux). 파일명을 OS에 맞게 조립.
# |           : 파이프. 앞 명령의 출력을 뒤 명령의 입력으로 넘김 (디스크에 저장 안 함)
# tar xz      : x=압축 해제, z=gzip 형식
# -C /tmp     : /tmp 디렉터리에 풀기

sudo mv /tmp/eksctl /usr/local/bin
# sudo : 관리자 권한으로 실행
# mv   : 파일 이동. /usr/local/bin 은 PATH에 포함된 경로라
#        이제 어디서든 eksctl 이라고 치면 실행된다.

eksctl create cluster -f cluster.yaml
# -f : 위에서 만든 설정 파일대로 클러스터를 생성
#
# ⏱ 여기서 18~22분 걸린다. 내부적으로 CloudFormation 스택을
#    여러 개(클러스터 → 노드그룹 2개 → IAM SA) 순차 생성하기 때문.
#    화면이 멈춘 게 아니라 대기 중이다.
