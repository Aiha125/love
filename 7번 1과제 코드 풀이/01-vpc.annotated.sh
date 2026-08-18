#!/bin/bash
# ↑ 셔뱅(shebang). 이 파일을 bash로 실행하라는 표시.

set -x
# set : 셸 옵션을 켜고 끄는 명령
# -x  : 실행되는 명령을 화면에 그대로 찍어줌(디버깅용). 어디서 멈췄는지 보기 좋음.

aws configure set default.region ap-northeast-2
# aws configure set : ~/.aws/config 파일에 설정값을 저장
# default.region    : 기본 프로필의 리전 항목
# ap-northeast-2    : 서울 리전. 이후 모든 명령에서 --region 생략 가능해짐.

aws configure set default.output json
# default.output json : 출력 형식을 JSON으로 고정 (text/table/yaml도 가능)


# ─────────────────────────────────────────────
# VPC 생성
# ─────────────────────────────────────────────
VPC=$(aws ec2 create-vpc --cidr-block 172.16.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=wskorea26-vpc}]' \
  --query Vpc.VpcId --output text)
# VPC=$( ... )        : 명령 실행 결과를 VPC 변수에 담는 "명령 치환"
# create-vpc          : 가상 네트워크(VPC) 생성
# --cidr-block        : VPC가 사용할 IP 대역. /16 = 172.16.0.0 ~ 172.16.255.255 (65,536개)
# --tag-specifications: 생성과 "동시에" 태그를 붙임 (나중에 create-tags 안 해도 됨)
#   ResourceType=vpc  : 태그를 붙일 대상 종류
#   Tags=[{Key=Name,Value=...}] : Name 태그. 콘솔 목록에 이름으로 표시되는 값
# --query Vpc.VpcId   : 응답 JSON에서 VpcId 필드만 뽑음 (JMESPath 문법)
# --output text       : 따옴표 없는 순수 문자열로 출력 → 변수에 담기 좋음

aws ec2 modify-vpc-attribute --vpc-id $VPC --enable-dns-support '{"Value":true}'
# enable-dns-support : VPC 안에서 AWS 제공 DNS 서버(169.254.169.253)를 쓸 수 있게 함
#                      끄면 파드가 도메인 이름을 못 찾음

aws ec2 modify-vpc-attribute --vpc-id $VPC --enable-dns-hostnames '{"Value":true}'
# enable-dns-hostnames : EC2 인스턴스에 DNS 호스트네임을 자동 부여
#                        EKS/ALB가 정상 동작하려면 위 두 개 모두 true여야 함


# ─────────────────────────────────────────────
# 인터넷 게이트웨이 (외부 통신 출입구)
# ─────────────────────────────────────────────
IGW=$(aws ec2 create-internet-gateway --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=book-igw}]' --query InternetGateway.InternetGatewayId --output text)
# create-internet-gateway : IGW 생성. 아직 어느 VPC에도 붙어있지 않은 상태.

aws ec2 attach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC
# attach-internet-gateway : 방금 만든 IGW를 VPC에 부착
#                           이걸 해야 퍼블릭 서브넷이 인터넷과 통신 가능


# ─────────────────────────────────────────────
# 서브넷 생성 (함수로 반복 작업 묶기)
# ─────────────────────────────────────────────
mksub(){ 
  aws ec2 create-subnet --vpc-id $VPC --cidr-block $2 --availability-zone $3 \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$1}]" --query Subnet.SubnetId --output text
}
# mksub(){ ... }        : 쉘 함수 정의. 같은 명령을 4번 쓰지 않으려고 만든 것.
# $1 $2 $3              : 함수 호출 시 넘긴 1·2·3번째 인자
#                         $1=이름, $2=CIDR, $3=가용영역
# --availability-zone   : 물리적으로 분리된 데이터센터 단위. 장애 격리를 위해 나눔.
# 큰따옴표(")를 쓴 이유  : 안에 $1 변수를 넣어야 하기 때문.
#                         작은따옴표(')는 변수를 치환하지 않음.

PUB_C=$(mksub wskorea26-pub-subnet-c   172.16.1.0/24   ap-northeast-2c)
PUB_D=$(mksub wskorea26-pub-subnet-d   172.16.2.0/24   ap-northeast-2d)
PRIV_C=$(mksub wskorea26-priv-subnet-c 172.16.201.0/24 ap-northeast-2c)
PRIV_D=$(mksub wskorea26-priv-subnet-d 172.16.202.0/24 ap-northeast-2d)
# pub  = 퍼블릭 서브넷  : 인터넷에서 직접 들어올 수 있음 (ALB, NAT가 여기 위치)
# priv = 프라이빗 서브넷: 인터넷에서 직접 못 들어옴 (EKS 노드, DB가 여기 위치)
# /24  = IP 256개짜리 대역
# c, d = 서로 다른 가용영역. 한쪽 AZ가 죽어도 서비스가 살아남게 하려고 2개로 나눔.

for s in $PUB_C $PUB_D; do 
  aws ec2 modify-subnet-attribute --subnet-id $s --map-public-ip-on-launch
done
# for ... do ... done       : 반복문. 퍼블릭 서브넷 2개에 같은 설정 적용
# --map-public-ip-on-launch : 이 서브넷에 뜨는 인스턴스에 공인 IP를 자동 부여


# ─────────────────────────────────────────────
# NAT 게이트웨이 (프라이빗 → 인터넷 단방향 통로)
# ─────────────────────────────────────────────
EIP_C=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
# allocate-address : 탄력적 IP(고정 공인 IP) 할당. NAT는 고정 IP가 필수.
# --domain vpc     : VPC용 EIP (예전 EC2-Classic과 구분)
# AllocationId     : EIP를 가리키는 ID. IP 주소 자체가 아님.

NGW_C=$(aws ec2 create-nat-gateway --subnet-id $PUB_C --allocation-id $EIP_C \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=book-ngw-c}]' --query NatGateway.NatGatewayId --output text)
# create-nat-gateway : NAT 게이트웨이 생성
# --subnet-id $PUB_C : NAT는 반드시 "퍼블릭" 서브넷에 놓아야 함.
#                      (자기가 인터넷에 나갈 수 있어야 남을 내보내줄 수 있으므로)
# 역할               : 프라이빗 서브넷의 노드가 밖으로 나가는 건 허용,
#                      밖에서 안으로 들어오는 건 차단

EIP_D=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
NGW_D=$(aws ec2 create-nat-gateway --subnet-id $PUB_D --allocation-id $EIP_D \
  --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=book-ngw-d}]' --query NatGateway.NatGatewayId --output text)
# AZ마다 NAT를 1개씩 두는 이유: c의 NAT가 죽어도 d의 노드는 계속 인터넷을 씀.

aws ec2 wait nat-gateway-available --nat-gateway-ids $NGW_C $NGW_D
# aws ... wait ... : 해당 상태가 될 때까지 "여기서 멈춰 기다림"
#                    NAT 생성은 2~3분 걸림. 스크립트가 멈춘 게 아니라 대기 중인 것.
#                    NAT가 available 되기 전에 라우팅을 걸면 실패하므로 필요한 단계.


# ─────────────────────────────────────────────
# 라우팅 테이블 (어느 트래픽을 어디로 보낼지 규칙표)
# ─────────────────────────────────────────────
mkrtb(){ 
  aws ec2 create-route-table --vpc-id $VPC --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$1}]" --query RouteTable.RouteTableId --output text
}
# 라우팅 테이블도 3개나 만들어야 하므로 함수로 묶음

PUBLIC_RT=$(mkrtb wskorea26-public-rtb)
PRIVATE_RT_C=$(mkrtb wskorea26-private-rtb-c)
PRIVATE_RT_D=$(mkrtb wskorea26-private-rtb-d)
# 퍼블릭은 1개를 공유(둘 다 IGW로 나가면 되니까)
# 프라이빗은 AZ별로 분리(각자 자기 AZ의 NAT로 나가야 하니까)

aws ec2 create-route --route-table-id $PUBLIC_RT     --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW
# create-route              : 라우팅 규칙 1줄 추가
# --destination-cidr-block  : 목적지 대역. 0.0.0.0/0 = "그 외 전부"(=인터넷)
# --gateway-id $IGW         : 그 트래픽을 IGW로 보냄

aws ec2 create-route --route-table-id $PRIVATE_RT_C  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NGW_C
aws ec2 create-route --route-table-id $PRIVATE_RT_D  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NGW_D
# --nat-gateway-id : 프라이빗은 IGW가 아니라 NAT로 내보냄

aws ec2 associate-route-table --route-table-id $PUBLIC_RT     --subnet-id $PUB_C
aws ec2 associate-route-table --route-table-id $PUBLIC_RT     --subnet-id $PUB_D
aws ec2 associate-route-table --route-table-id $PRIVATE_RT_C  --subnet-id $PRIV_C
aws ec2 associate-route-table --route-table-id $PRIVATE_RT_D  --subnet-id $PRIV_D
# associate-route-table : 만든 규칙표를 실제 서브넷에 "연결"
#                         연결하지 않으면 규칙이 있어도 적용되지 않음


# ─────────────────────────────────────────────
# 쿠버네티스용 특수 태그
# ─────────────────────────────────────────────
aws ec2 create-tags --resources $PUB_C $PUB_D --tags Key=kubernetes.io/role/elb,Value=1
# kubernetes.io/role/elb=1 : "인터넷용 로드밸런서를 여기 만들어라"라고
#                            AWS Load Balancer Controller에게 알려주는 약속된 태그.
#                            이 태그가 없으면 Ingress를 만들어도 ALB가 안 생김.

aws ec2 create-tags --resources $PRIV_C $PRIV_D --tags Key=kubernetes.io/role/internal-elb,Value=1 Key=karpenter.sh/discovery,Value=wskorea26-cluster
# internal-elb=1          : "내부용 로드밸런서는 여기" 라는 표시
# karpenter.sh/discovery  : Karpenter(노드 자동 확장 도구)가 쓸 서브넷을 찾는 태그.
#                           값은 클러스터 이름과 맞춰야 함.
