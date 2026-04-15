# OCI Cost Reporting Playbook

이 문서는 `waffle-world-oci` 운영 관점에서, OCI Cost Analysis 또는 Cost Reports 데이터를 가져와 월별 비용 문서를 만들고 Slack에 공유하는 구조를 설명한다. 구현 코드는 아직 만들지 않고, 어떤 식으로 설계하면 되는지에 초점을 둔다.

## 목표

- 매달 `wafflestudio` 관련 OCI 비용을 한 번에 볼 수 있게 한다.
- 총액만 보는 것이 아니라 `왜 올랐는지`까지 추적할 수 있게 한다.
- 이 레포의 실제 리소스 구조와 연결되는 비용 축을 문서화한다.
- 최종적으로는 Slack에 월간 요약을 자동 전송하되, 원본 데이터와 월간 리포트는 다시 확인할 수 있게 남긴다.

## 먼저 정리할 전제

이 레포는 OKE 클러스터와 그 위에 올라가는 워크로드를 GitOps로 관리한다. 따라서 비용을 볼 때도 단순히 "OKE 비용"만 보는 것이 아니라, 아래처럼 여러 OCI 서비스에 나뉘어 나타나는 비용을 함께 봐야 한다.

- `Kubernetes Engine` 또는 `Container Engine`: 클러스터 관리 비용
- `Compute`: 워커 노드 풀 비용
- `Network Load Balancer` 또는 `Load Balancer`: `Service type=LoadBalancer`로 생긴 인그레스 비용
- `Block Volume` 또는 `File Storage`: PVC, 상태 저장 워크로드 비용
- `Container Registry`: 이미지 저장 및 전송 비용
- `Logging`, `Monitoring`: 관측성 관련 비용
- `VCN` 계열 네트워크 비용: 퍼블릭 IP, NAT, 트래픽 관련 비용

이 해석은 현재 레포 구조와 연결된다.

- [argocd/cluster-autoscaler/values.yaml](/Users/junby/Coding/waffle-world-oci/argocd/cluster-autoscaler/values.yaml): OKE 노드 풀 스케일링
- [argocd/istio-gateway/values.yaml](/Users/junby/Coding/waffle-world-oci/argocd/istio-gateway/values.yaml): `LoadBalancer` 타입의 게이트웨이 서비스
- [docs/oke-cluster-architecture.md](/Users/junby/Coding/waffle-world-oci/docs/oke-cluster-architecture.md): 현재 OKE 아키텍처 설명

## 어떤 소스를 기준 데이터로 쓸까

OCI에서는 비용 데이터를 가져오는 방법이 크게 세 가지다.

### 1. Cost Analysis / Usage API

월별 Slack 요약이나 "이번 달 왜 비쌌는지" 같은 분석에는 이 방식이 제일 잘 맞는다.

- Cost Analysis는 OCI 콘솔의 시각화 도구다.
- Oracle 문서에 따르면 Cost Analysis는 Usage API를 사용하며, `COST` 또는 `USAGE` 기준으로 조회할 수 있다.
- `MONTHLY`, `DAILY`, `HOURLY` 단위 조회가 가능하고, 필터와 `groupBy`를 조합할 수 있다.
- `service`, `skuName`, `compartmentPath`, `resourceId` 같은 축으로 비용 원인을 좁혀갈 수 있다.

권장 용도:

- 월간 총액 요약
- 전월 대비 증감
- 서비스별 상위 비용
- 컴파트먼트별 상위 비용
- OKE 관련 비용만 다시 좁혀 보기
- 특정 비용 급증 구간의 리소스 식별

### 2. Cost Reports

원본 보관과 상세 감사에는 이 방식이 더 좋다.

- Oracle 문서에 따르면 Cost Reports는 CSV 파일이며, Oracle 소유 Object Storage에 저장된다.
- Cost Reports는 자동으로 생성되고, 일반적으로 6시간 단위의 사용 데이터를 담는다.
- Cost report는 Object Storage에 저장되며, 리소스 레벨의 상세 비용 확인에 적합하다.
- 2025년 1월 31일부로 기존 Usage Report는 deprecated 되었고, Cost Report 또는 FOCUS Cost Report 사용이 권장된다.

권장 용도:

- 원본 데이터 보관
- 월말 정산 검증
- BI나 스프레드시트 후처리
- Slack에는 너무 자세한 데이터를 별도 문서 링크로 연결하고 싶을 때

### 3. Scheduled Reports

콘솔에서 이미 만들어 둔 Cost Analysis Saved Report를 정기적으로 Object Storage로 떨구고 싶다면 유용하다.

- Oracle 문서에 따르면 Saved Report를 기반으로 단발 또는 반복 Scheduled Report를 만들 수 있다.
- 월간 CSV/PDF를 버킷에 쌓는 운영에는 편하다.
- 다만 Slack에 맞춘 메시지 포맷이나 조건부 요약은 결국 별도 후처리가 필요하다.

권장 용도:

- "일단 월별 CSV를 버킷에 자동 저장"이 목표일 때
- 운영자가 콘솔에서 보고 있는 화면과 같은 기준을 그대로 보존하고 싶을 때

## 우리 레포 기준 권장안

`Slack 월간 요약 + 원인 추적 + 문서 아카이브`까지 생각하면 다음 구성이 가장 균형이 좋다.

1. Cost Analysis/Usage API를 메인 조회 소스로 쓴다.
2. 필요하면 Cost Reports를 원본 아카이브로 같이 보관한다.
3. 이 레포의 `docs/` 아래에 월간 요약 문서를 남긴다.
4. Slack에는 사람이 읽기 좋은 요약만 보낸다.

이 조합이 좋은 이유는 다음과 같다.

- Cost Analysis/Usage API는 `groupBy`와 필터가 강해서 월간 요약에 적합하다.
- Cost Reports는 상세하지만 Slack 메시지로 바로 쓰기에는 너무 크다.
- 이 레포는 이미 운영 문서를 담고 있으므로, 월간 비용 문서도 같은 맥락에서 관리하기 좋다.

## `wafflestudio` compartment에서 비용을 가져오는 방식

핵심은 "어느 축으로 비용을 자를지"를 먼저 정하는 것이다.

가장 먼저 볼 축:

- `compartmentPath` 또는 `compartmentId`
- `service`
- `skuName`
- `resourceId`
- 필요하면 `tagNamespace/tagKey/tagValue`

실무적으로는 보통 아래 순서가 좋다.

1. `wafflestudio` 관련 상위 compartment 전체의 월간 총액을 본다.
2. 같은 기간을 `service` 기준으로 나눈다.
3. OKE 관련 서비스만 다시 좁혀서 `skuName`과 `resourceId`까지 본다.
4. 원인 후보를 문서화한다.

예를 들어 월별 조회 로직은 이런 식으로 생각하면 된다.

- 월간 총액: `compartmentPath = wafflestudio/...`, `queryType = COST`, `granularity = MONTHLY`
- 서비스별: 위와 같은 범위에서 `groupBy = ["service"]`
- 원인 추적: `groupBy = ["service", "skuName", "compartmentPath", "resourceId"]`

Oracle 문서상 Cost Analysis에서는 `service`, `skuName`, `compartmentPath`, `compartmentId`, `resourceId`, `region` 등으로 그룹핑할 수 있다. 또한 비용 원인을 찾고 싶을 때 `Resource OCID`로 그룹핑해서 책임 리소스를 식별하는 흐름을 공식 문서에서 안내하고 있다.

## 실제로 가져올 때의 접근 방식

### 콘솔에서 바로 보는 방법

가장 빠른 1차 확인은 OCI Console의 Cost Analysis 화면이다.

추천 순서:

1. 기간을 지난달 한 달로 맞춘다.
2. Scope를 `wafflestudio` 관련 compartment로 제한한다.
3. 우선 `Group by = Service`로 본다.
4. 그다음 `Group by = Resource OCID` 또는 `SKU`로 바꿔 급증 원인을 찾는다.
5. 월간 문서에는 총액, 상위 서비스, 원인 2~3개만 추린다.

이 방법의 장점은 팀이 먼저 눈으로 기준을 맞출 수 있다는 점이다. 구현 전에 "우리가 어떤 화면을 truth로 볼지"를 합의하기 좋다.

### CLI/API로 가져오는 방법

자동화는 결국 Usage API 기반이 가장 단순하다. OCI CLI에서는 `request-summarized-usages` 명령으로 같은 데이터를 가져올 수 있다.

흐름은 보통 아래처럼 잡으면 된다.

1. 지난달 시작일과 종료일을 정한다.
2. `queryType = COST`로 둔다.
3. `granularity = MONTHLY`로 둔다.
4. `compartmentPath` 또는 `compartmentId`로 `wafflestudio` 범위를 제한한다.
5. `groupBy`를 바꿔가며 총액, 서비스별, 원인별 데이터를 각각 가져온다.

예시 요청 구조:

```json
{
  "tenantId": "ocid1.tenancy.oc1..example",
  "timeUsageStarted": "2026-03-01T00:00:00Z",
  "timeUsageEnded": "2026-04-01T00:00:00Z",
  "queryType": "COST",
  "granularity": "MONTHLY",
  "groupBy": ["service", "skuName", "compartmentPath", "resourceId"],
  "filter": {
    "operator": "AND",
    "dimensions": [
      {
        "key": "compartmentPath",
        "value": "wafflestudio"
      }
    ]
  }
}
```

실제 키 이름이나 필터 중첩 구조는 tenancy 환경에 맞게 조금 달라질 수 있으므로, 첫 실행 때는 OCI CLI의 `--generate-full-command-json-input` 또는 SDK 모델 문서를 같이 보는 것이 안전하다.

문서화 관점에서 중요한 건 "한 번의 거대한 요청"보다 "의미가 다른 3개의 요청"으로 나누는 것이다.

- 요청 1: 월간 총액
- 요청 2: 서비스별 비용
- 요청 3: OKE 관련 원인 추적용 비용

이렇게 나누면 Slack 요약과 월간 문서에 각각 맞는 결과를 만들기 쉽다.

## 비용을 읽을 때의 해석 규칙

이 부분이 중요하다. OKE를 쓴다고 해서 비용이 전부 `Kubernetes Engine`으로만 잡히지 않는다.

### 클러스터 관리 비용

- `Kubernetes Engine` 또는 유사한 OKE 서비스명으로 나타나는 비용
- 흔히 "클러스터 자체를 유지하는 비용"으로 해석한다

### 워커 노드 비용

- 보통 `Compute`
- 노드풀 스펙, 오토스케일링 최소/최대 개수, 상시 떠 있는 베이스 노드 수가 직접적인 원인이다

### 인그레스 / 외부 노출 비용

- `Load Balancer` 또는 `Network Load Balancer`
- 이 레포에서는 Istio ingress gateway가 `LoadBalancer` 타입이므로 이 축을 따로 봐야 한다

### 스토리지 비용

- `Block Volume`, `File Storage`
- Mongo, Valkey, 기타 상태 저장 워크로드가 있으면 특히 중요하다

### 부가 인프라 비용

- `Container Registry`, `Logging`, `Monitoring`, 네트워크 관련 서비스

Slack이나 문서에는 이 해석 규칙을 같이 적어줘야, 비용 변동이 생겼을 때 "누가 뭘 봐야 하는지"가 바로 연결된다.

## 태그 전략이 있으면 훨씬 좋아진다

Oracle 문서에서도 비용 추적에는 Compartment 또는 Tag 기준 그룹핑을 권장한다.

추천 태그:

- `team=wafflestudio`
- `service=snutt|siksha|wadot|...`
- `env=prod|dev`
- `cluster=main-oke`
- `cost-center=platform`

태그가 잘 붙어 있으면 월간 문서에서 아래처럼 바로 정리할 수 있다.

- 팀별 비용
- 서비스별 비용
- prod/dev 비용 비중
- shared infra와 app infra 분리

태그가 없다면 1차 버전은 `compartment + service + resourceId`만으로도 시작할 수 있다.

## 문서는 어떻게 남기면 좋을까

이 레포에는 월별 비용 요약을 `docs/cost-reports/` 같은 경로에 쌓는 방식을 추천한다.

예시 구조:

```text
docs/
  cost-reports/
    2026-03.md
    2026-04.md
  oci-cost-reporting-playbook.md
```

월간 문서 템플릿 예시:

```md
# OCI Cost Report - 2026-03

## Summary
- 총 비용:
- 전월 대비:
- 주요 증가 원인:

## Top Services
- Compute:
- Kubernetes Engine:
- Network Load Balancer:

## Top Compartments
- wafflestudio/prod:
- wafflestudio/dev:

## OKE Focus
- Cluster management:
- Worker nodes:
- Ingress load balancer:
- Persistent storage:

## Notes
- 이번 달 특이사항
- 다음 달 액션 아이템
```

이렇게 두면 Slack은 짧게 보내고, 자세한 내용은 문서 링크로 연결할 수 있다.

## Slack에는 무엇을 보내면 좋을까

Slack은 원본 데이터 덤프가 아니라 "의사결정용 요약"이 되어야 한다.

권장 메시지 구성:

- 대상 월
- 총 비용
- 전월 대비 증감
- 상위 3개 서비스
- OKE 관련 비용 비중
- 가장 큰 증가 원인 2~3개
- 자세한 문서 링크

예시:

```text
[OCI Cost] 2026-03
- Total: $1,240 (+18% MoM)
- Top services: Compute $620, Kubernetes Engine $180, NLB $140
- OKE-related: $980 (79%)
- Main drivers:
  - Compute in wafflestudio/prod
  - NLB for istio ingress
  - Block Volume for stateful workloads
- Doc: docs/cost-reports/2026-03.md
```

Slack 공식 문서 기준으로 Incoming Webhook은 고유 URL에 JSON payload를 보내는 방식이고, 일반 텍스트뿐 아니라 formatting과 layout blocks도 사용할 수 있다. 따라서 첫 버전은 텍스트로 시작하고, 나중에는 Block Kit 스타일로 확장하면 된다.

## 운영 플로우는 어떻게 잡는 게 좋을까

가장 무난한 월간 운영 플로우는 아래와 같다.

1. 매달 초, 전월 데이터를 기준으로 조회한다.
2. `wafflestudio` 관련 compartment 범위를 필터한다.
3. 서비스별/컴파트먼트별/OKE 관련 축으로 요약한다.
4. `docs/cost-reports/YYYY-MM.md` 문서를 생성하거나 갱신한다.
5. Slack에 요약을 전송한다.
6. 급증 서비스가 있으면 해당 월 문서에 조사 메모를 남긴다.

운영 시점은 월초 바로보다는, 비용 집계가 어느 정도 안정된 뒤인 `매월 2일~5일` 정도가 현실적이다. Oracle Cost Analysis 문서에는 데이터가 표시되기까지 최대 48시간이 걸릴 수 있다고 안내되어 있으므로, 첫 실행일은 이 지연을 감안해 잡는 것이 좋다.

## 구현 방식을 고른다면 세 가지 옵션이 있다

### 옵션 A. GitHub Actions + Usage API

가장 추천하는 기본안이다.

- 레포 안에서 문서와 자동화를 같이 관리 가능
- 월간 실행 스케줄을 GitHub Actions로 붙이기 쉬움
- Slack webhook 연동도 단순함
- 이 레포의 GitOps 맥락과 잘 맞음

잘 맞는 경우:

- "레포에서 문서까지 같이 관리하고 싶다"
- "월 1회 요약만 잘 가면 된다"

### 옵션 B. OCI Scheduled Reports + 후처리 잡

- 콘솔 Saved Report를 기준으로 CSV/PDF를 버킷에 생성
- 후처리 잡이 그 파일을 읽어서 Slack에 재가공

잘 맞는 경우:

- 콘솔에서 비용 리포트를 이미 수동으로 잘 보고 있음
- 콘솔 설정을 기준 truth로 삼고 싶음

### 옵션 C. Cost Reports 적재 + 별도 분석 파이프라인

- Object Storage의 Cost Report CSV를 지속 적재
- 별도 데이터 처리 후 Slack/문서 생성

잘 맞는 경우:

- 장기 추세 분석
- 재무/회계 검증
- Tableau, Sheets, BI 도구와 연동

## 이 레포에 붙인다면 어떤 디렉터리 구성이 자연스러운가

구현을 나중에 한다면 아래 정도가 무난하다.

```text
docs/
  cost-reports/
  oci-cost-reporting-playbook.md

scripts/
  cost-report/
    fetch-monthly-costs.py
    build-report.py
    send-slack.py

.github/workflows/
  monthly-cost-report.yml
```

지금 단계에서는 `docs/`만 먼저 두고, 구현은 필요할 때 붙이면 된다.

## 시작할 때 필요한 IAM/접근 권한

Oracle 공식 문서 기준으로 확인해야 할 포인트는 아래다.

- Cost Analysis 조회: `Allow group <group_name> to read usage-report in tenancy`
- Cost Analysis Saved Report 관리: `Allow group <group_name> to manage usage-report in tenancy`
- Cost Reports 다운로드: Oracle이 소유한 reporting tenancy의 Object Storage를 읽을 수 있도록 cross-tenancy policy가 필요함
- Scheduled Reports를 Object Storage 버킷에 쓰려면 `metering_overlay` 서비스가 대상 버킷에 object create/delete/read 할 수 있는 정책이 필요함

예를 들어 Cost Reports 문서에는 `define tenancy usage-report ...` 와 `endorse group ... to read objects in tenancy usage-report` 형태의 예시가 나온다. Scheduled Reports 문서에는 `Allow service metering_overlay to manage objects ...` 형태의 버킷 접근 정책 예시가 나온다. 실제 적용 전에는 반드시 최신 문서와 tenancy 정책 문법으로 최종 확인하는 것이 안전하다.

## 바로 문서화할 수 있는 첫 버전 제안

첫 버전은 과하게 욕심내지 않는 게 좋다.

1. 범위는 `wafflestudio` 관련 compartment 전체로 잡는다.
2. 월 1회만 본다.
3. 문서에는 아래 4가지만 넣는다.

- 총 비용
- 전월 대비
- 상위 서비스 5개
- OKE 관련 비용 메모

4. Slack에는 문서 요약만 보낸다.
5. 태그 기반 정교한 분석은 2차로 미룬다.

이렇게 시작하면 구현 난이도는 낮고, 팀이 실제로 보는 가치도 바로 나온다.

## 참고 링크

- Oracle Cost Analysis Overview: https://docs.oracle.com/en-us/iaas/Content/Billing/Concepts/costanalysisoverview.htm
- Oracle Usage API CLI `request-summarized-usages`: https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/usage-api/usage-summary/request-summarized-usages.html
- Oracle Python SDK `RequestSummarizedUsagesDetails`: https://docs.oracle.com/en-us/iaas/tools/python/latest/api/usage_api/models/oci.usage_api.models.RequestSummarizedUsagesDetails.html
- Oracle Python SDK `Filter`: https://docs.oracle.com/en-us/iaas/tools/python/latest/api/usage_api/models/oci.usage_api.models.Filter.html
- Oracle Cost Reports Overview: https://docs.oracle.com/iaas/Content/Billing/Concepts/costusagereportsoverview.htm
- Oracle Downloading a Cost Report: https://docs.oracle.com/en-us/iaas/Content/Billing/Tasks/download-cost-usage-report.htm
- Oracle Scheduled Reports Overview: https://docs.oracle.com/en-us/iaas/Content/Billing/Concepts/scheduledreportoverview.htm
- Oracle Creating a Cost Analysis Scheduled Report: https://docs.oracle.com/en-us/iaas/Content/Billing/Tasks/schedule-create.htm
- Slack Incoming Webhooks: https://docs.slack.dev/messaging/sending-messages-using-incoming-webhooks/
