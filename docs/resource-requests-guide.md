# Kubernetes Resource Requests 가이드

## 개요

Kubernetes의 `resources.requests`는 파드를 노드에 스케줄링할 때 **예약하는 최소 보장량**이다.
Cluster Autoscaler(CA)는 실제 CPU 사용량(usage)이 아닌 **requests 합산**을 기준으로 노드 축소 가능 여부를 판단하므로,
requests가 과도하게 높으면 실제 여유가 있어도 노드 축소가 불가능하다.

## requests vs limits 차이

| 항목 | requests | limits |
|---|---|---|
| 역할 | 스케줄링 시 노드에서 예약 | 최대 허용치 (초과 시 throttle/OOM) |
| CA 기준 | ✅ 사용 | ❌ 미사용 |
| 실제 사용 초과 | 허용 (여유 CPU 있으면 더 사용 가능) | 불허 (CPU throttle 발생) |

> requests를 낮게 잡아도 실제로 CPU를 더 많이 쓸 수 있다.
> 단, 노드 CPU가 포화 상태일 때는 requests 비율대로 CPU 시간이 배분된다.

## 권장 기준

### CPU Requests

```
권장 requests = 평상시 usage의 3~5배
최솟값: 10m
```

| 서비스 유형 | 권장 배율 | 이유 |
|---|---|---|
| Spring Boot / JVM 서버 | 평상시 usage × 5 | JVM 워밍업 스파이크 고려 |
| Next.js / Node.js 웹 | 평상시 usage × 3 | 빌드/SSR 스파이크 |
| DB (MongoDB, Postgres) | 평상시 usage × 3 | 쿼리 스파이크 고려 |
| Valkey / Redis | 평상시 usage × 3 | 대체로 낮음, 스파이크 적음 |
| 배치 작업 | 실행 시 peak usage × 1.2 | 실제 피크 기준으로 설정 |

### Memory Requests

```
권장 requests = 평상시 usage의 1.5~2배
반드시 limits도 함께 설정
```

메모리는 압축이 불가하므로 requests를 너무 낮게 잡으면 OOM 위험이 있다.
JVM 서버는 heap 크기를 `-Xmx` 옵션으로 고정하고 그에 맞게 limits을 설정한다.

## 모니터링 방법

### 현재 requests vs usage 비교

```bash
# 노드별 requests 합산 확인 (CA가 보는 값)
kubectl describe nodes | grep -A5 "Allocated resources"

# 파드 실제 사용량
kubectl top pods -A --sort-by=cpu

# 노드 실제 사용량
kubectl top nodes
```

### 점검 주기

- **월 1회**: `kubectl top pods -A`로 usage 대비 requests 배율이 10x 이상인 파드 점검
- **신규 서비스 배포 후 2주**: 안정화 후 requests 재조정

## 팀별 적용 현황 (2026-08-09 기준)

| 팀/서비스 | 파드 | 변경 전 | 변경 후 | 실제 usage |
|---|---|---|---|---|
| n8n-prod | n8n-app | 500m | 50m | 3m |
| snutt-prod | snutt-timetable | 200m | 30m | 3m |
| snutt-prod | snutt-ev | 150m | 20m | 2m |
| snutt-prod | snutt-ev-web | 100m | 15m | 2m |
| snutt-prod | snutt-theme-market | 100m | 15m | 1m |
| snutt-prod | snutt-valkey | 100m | 15m | 2m |
| snutt-prod | snutt-mongo | 100m | 30m | 10m |
| siksha-prod | siksha-spring-server | 200m | 30m | 4m |
| siksha-prod | siksha-valkey | 100m | 15m | 2m |
| siksha-dev | siksha-spring-server | 100m | 20m | 4m |
| slack-viz-prod | slack-viz-mongodb | 200m | 20m | 4m |
| slack-viz-prod | slack-viz-app | 100m | 20m | 0m |
| hangsha-prod | hangsha-kiwi | 100m | 15m | 2m |
| hangsha-prod | hangsha-manticore | 100m | 30m | 9m |
| hangsha-prod | hangsha-valkey | 100m | 15m | - |
| hangsha-dev | hangsha-kiwi | 100m | 15m | 2m |
| hangsha-dev | hangsha-manticore | 100m | 30m | 10m |
| allclear-prod | allclear-valkey | 100m | 15m | 2m |
| allclear-prod | allclear-db | 100m | 30m | 1m |
| allclear-dev | allclear-web | 100m | 10m | 1m |
| waffle-alert-prod | waffle-alert | 100m | 10m | 1m |

> pecan-prod는 GPU 연산 워크로드 특성상 1000m 유지

## 주의사항

- requests를 너무 낮게 잡으면 HPA가 오작동할 수 있다. HPA의 `averageUtilization` 기준은 requests 대비 usage 비율이므로, requests가 낮으면 HPA가 더 빨리 스케일 아웃된다.
- DB, StatefulSet은 requests를 너무 낮게 잡지 않는다. 재스케줄 시 데이터 이동 비용이 크다.
- 배치 작업은 상시 파드와 분리해서 requests를 높게 잡아도 된다 (실행 시간이 짧으므로 CA 영향 적음).
