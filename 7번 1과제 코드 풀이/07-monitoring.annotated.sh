#!/bin/bash
set -x

REGION="ap-northeast-2"
CLUSTER_NAME="wskorea26-cluster"
NAMESPACE="monitoring"          # 모니터링 도구들을 모아둘 네임스페이스

kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
# "있으면 통과, 없으면 생성" 관용구 (06번 설명 참고)

PUB_SUBNET_C=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=wskorea26-pub-subnet-c" --region $REGION --query "Subnets[0].SubnetId" --output text)
PUB_SUBNET_D=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=wskorea26-pub-subnet-d" --region $REGION --query "Subnets[0].SubnetId" --output text)
# Grafana용 ALB를 놓을 퍼블릭 서브넷

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
# Prometheus 커뮤니티 차트 저장소 등록
helm repo add aws https://aws.github.io/eks-charts
# AWS 공식 차트 저장소 (fluent-bit이 여기 있음)
helm repo update
# 두 저장소의 차트 목록 갱신

eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --name=fluent-bit \
  --namespace=$NAMESPACE \
  --attach-policy-arn=arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
  --approve \
  --override-existing-serviceaccounts
# fluent-bit(로그 수집기)이 CloudWatch에 로그를 쓸 수 있도록 IRSA 구성
# arn:aws:iam::aws:policy/... : 계정 번호 자리가 aws 이면 "AWS 관리형 정책"이라는 뜻.
#   CloudWatchAgentServerPolicy : 로그 그룹 생성·로그 전송 권한 묶음
# ⏱ CloudFormation을 거쳐 2~3분


cat <<EOF > prometheus-values.yaml
# Helm 차트의 기본 설정을 덮어쓸 값 파일. YAML이라 주석 가능.

prometheusOperator:
  nodeSelector:
    node-type: addon
    # 오퍼레이터(Prometheus를 관리하는 관리자 파드)를 애드온 노드에 고정

prometheus:
  prometheusSpec:
    nodeSelector:
      node-type: addon
      # 지표를 실제로 저장하는 Prometheus 서버 본체

alertmanager:
  alertmanagerSpec:
    nodeSelector:
      node-type: addon
      # 알림을 발송하는 컴포넌트

kube-state-metrics:
  nodeSelector:
    node-type: addon
    # 쿠버네티스 오브젝트 상태(파드 개수, 재시작 횟수 등)를 지표로 변환해주는 컴포넌트

grafana:
  adminUser: "skills-${BNUM}-admin"
    # \${BNUM} 은 스크립트 실행 전에 export BNUM=<비번호> 로 넣어둔 환경변수.
    # 비어 있으면 계정이 "skills--admin" 이 되어 로그인이 안 되니 반드시 먼저 export 할 것.
  adminPassword: '\\\$korea26!!'
    # 비밀번호에 \$ 기호가 들어가는데, \$ 는 셸에서 변수 시작 문자라 그대로 쓰면 사라진다.
    # 히어독을 거치며 한 번, YAML을 거치며 한 번 해석되므로 역슬래시를 겹쳐 이스케이프한 것.
    # 최종 값은  \$korea26!!
  nodeSelector:
    node-type: addon
  defaultDashboardsEnabled: false
    # 차트가 기본 제공하는 수십 개 대시보드를 끔.
    # 과제에서 요구하는 대시보드만 깔끔하게 남기기 위함.

prometheus-node-exporter:
  tolerations:
    - key: "node-type"
      operator: "Equal"
      value: "app"
      effect: "NoSchedule"
      # node-exporter는 "모든 노드"의 CPU·메모리를 수집해야 하는 DaemonSet이다.
      # 앱 노드에 taint가 걸려 있으므로 toleration을 줘야 앱 노드에도 배치된다.
      # 이게 없으면 앱 노드 지표가 통째로 빠진다.
EOF

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace $NAMESPACE \
  -f prometheus-values.yaml
# helm upgrade --install : 없으면 설치, 있으면 업그레이드 (재실행해도 안전한 관용구)
# monitoring             : 릴리스 이름. 이 이름이 리소스 앞에 붙는다.
#                          → 그래서 Grafana 서비스 이름이 monitoring-grafana 가 된다.
# kube-prometheus-stack  : Prometheus + Grafana + Alertmanager + 익스포터 묶음 차트
# -f                     : 위에서 만든 값 파일 적용
# ⏱ 4~6분


cat <<EOF > fluentbit-values.yaml
serviceAccount:
  create: false
  name: fluent-bit
  # 차트가 SA를 새로 만들지 않고, 위에서 IRSA로 만든 fluent-bit SA를 사용

tolerations:
- key: "node-type"
  operator: "Equal"
  value: "app"
  effect: "NoSchedule"
  # fluent-bit도 DaemonSet이라 앱 노드의 로그를 걷으려면 toleration이 필요

cloudWatchLogs:
  enabled: true
  region: "$REGION"
  logGroupName: "/aws/eks/${CLUSTER_NAME}/pods-logs"
    # 로그가 모일 CloudWatch 로그 그룹 이름
  autoCreateGroup: true
    # 로그 그룹이 없으면 자동 생성
  logStreamPrefix: "fluentbit-"
    # 각 로그 스트림 이름 앞에 붙일 접두사
EOF

helm upgrade --install fluent-bit aws/aws-for-fluent-bit \
  --namespace $NAMESPACE \
  -f fluentbit-values.yaml
# 컨테이너 로그를 CloudWatch로 전송하는 수집기 설치
# ⏱ 1분


cat <<EOF > grafana-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-ingress
  namespace: monitoring
  annotations:
    alb.ingress.kubernetes.io/load-balancer-name: wskorea26-grafana-alb
    alb.ingress.kubernetes.io/scheme: internet-facing
      # Grafana는 브라우저로 봐야 하므로 인터넷에서 접근 가능해야 함
    alb.ingress.kubernetes.io/subnets: $PUB_SUBNET_C,$PUB_SUBNET_D
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /login
      # Grafana는 로그인 전에도 /login 이 200을 돌려주므로 헬스체크 경로로 적합
spec:
  ingressClassName: alb
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix        # 모든 경로를 Grafana로
        backend:
          service:
            name: monitoring-grafana
              # 릴리스 이름(monitoring) + 차트명(grafana) 조합으로 자동 생성된 서비스 이름
            port:
              number: 80
---
# --- : YAML에서 문서 구분자. 한 파일에 여러 오브젝트를 담을 때 사용.
apiVersion: v1
kind: ConfigMap                 # 설정 데이터를 담는 오브젝트
metadata:
  name: wskorea26-monitoring-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
    # 이 라벨이 핵심.
    # Grafana 차트의 사이드카 컨테이너가 이 라벨이 붙은 ConfigMap을 자동으로 찾아
    # 대시보드로 등록해준다. 라벨이 없으면 대시보드가 나타나지 않는다.
data:
  wskorea26-monitoring.json: |
  # | (파이프) : YAML의 리터럴 블록. 아래 들여쓴 내용을 줄바꿈 그대로 문자열로 담는다.
  #
  # ⚠ 아래는 JSON이라 안에 # 주석을 넣을 수 없다. 구조 설명을 여기 적어둔다.
  #   "uid": "wskorea26"        : 대시보드 고유 ID. URL(/d/wskorea26/...)에 쓰인다.
  #   "title"                   : 대시보드 이름
  #   "refresh": "5s"           : 5초마다 자동 갱신
  #   "time": from now-1h to now: 기본 조회 구간 = 최근 1시간
  #   "panels"                  : 그래프 하나하나가 패널. 각 패널의 항목은 아래와 같다.
  #     "type": "timeseries"    : 시간에 따른 선 그래프
  #     "type": "stat"          : 큰 숫자 하나만 보여주는 패널
  #     "gridPos"               : 화면상 위치와 크기.
  #                               w는 24칸 기준 너비, h는 높이, x·y는 좌상단 좌표
  #     "datasource"            : 지표를 가져올 곳 (prometheus)
  #     "targets[].expr"        : 실제 PromQL 질의문
  #
  #   PromQL 함수 뜻:
  #     rate(X[5m])             : 최근 5분간의 초당 증가율. 계속 커지는 카운터를
  #                               "속도"로 바꿔 보는 표준 기법.
  #     sum(...) by (a, b)      : a, b 라벨별로 묶어 합산
  #     count(...)              : 조건에 맞는 시계열 개수를 셈
  #     container!=''           : 컨테이너 이름이 빈 값인 시계열 제외.
  #                               (파드 전체 합계용 가짜 항목을 걸러내는 관용구)
  #     container_cpu_usage_seconds_total        : 컨테이너 누적 CPU 사용 시간
  #     container_memory_working_set_bytes       : 실제 사용 중인 메모리
  #     kube_pod_status_phase{phase='Running'}   : 실행 중인 파드
  #     kube_pod_container_status_restarts_total : 컨테이너 재시작 누적 횟수
  #     container_network_receive_bytes_total    : 수신한 누적 바이트
    {
      "annotations": { "list": [] },
      "editable": true,
      "fiscalYearStartMonth": 0,
      "graphTooltip": 0,
      "id": null,
      "uid": "wskorea26",
      "links": [],
      "liveNow": false,
      "panels": [
        {
          "id": 1,
          "title": "컨테이너의 CPU 사용량",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
          "datasource": {"type": "prometheus"},
          "targets": [
            {
              "expr": "sum(rate(container_cpu_usage_seconds_total{container!=''}[5m])) by (container, pod)",
              "refId": "A"
            }
          ]
        },
        {
          "id": 2,
          "title": "컨테이너의 메모리 사용량",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0},
          "datasource": {"type": "prometheus"},
          "targets": [
            {
              "expr": "sum(container_memory_working_set_bytes{container!=''}) by (container, pod)",
              "refId": "A"
            }
          ]
        },
        {
          "id": 3,
          "title": "실행중인 Pod 개수",
          "type": "stat",
          "gridPos": {"h": 8, "w": 8, "x": 0, "y": 8},
          "datasource": {"type": "prometheus"},
          "targets": [
            {
              "expr": "count(kube_pod_status_phase{phase='Running'})",
              "refId": "A"
            }
          ]
        },
        {
          "id": 4,
          "title": "컨테이너의 재시작 횟수",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 8, "x": 8, "y": 8},
          "datasource": {"type": "prometheus"},
          "targets": [
            {
              "expr": "sum(kube_pod_container_status_restarts_total) by (container, pod)",
              "refId": "A"
            }
          ]
        },
        {
          "id": 5,
          "title": "컨테이너의 네트워크 트래픽 수신량",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 8, "x": 16, "y": 8},
          "datasource": {"type": "prometheus"},
          "targets": [
            {
              "expr": "sum(rate(container_network_receive_bytes_total[5m])) by (pod)",
              "refId": "A"
            }
          ]
        }
      ],
      "refresh": "5s",
      "schemaVersion": 38,
      "style": "dark",
      "tags": [],
      "time": {
        "from": "now-1h",
        "to": "now"
      },
      "timepicker": {},
      "timezone": "",
      "title": "wskorea26-monitoring",
      "version": 1
    }
EOF

kubectl apply -f grafana-ingress.yaml
# Ingress와 ConfigMap을 함께 적용.
# ⏱ Grafana용 ALB 생성에 3~5분, DNS 이름이 풀리기까지 추가 1~3분.
#
# 접속: http://<ALB주소>/d/wskorea26/wskorea26-monitoring
# 계정: skills-<비번호>-admin / \$korea26!!
