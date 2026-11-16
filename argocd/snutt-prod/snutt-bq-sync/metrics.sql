-- 대시보드용 집계 테이블(snutt_metrics). views.sql 다음에 매일 실행한다.
-- 대시보드는 이 데이터셋만 조회한다. 원본을 매번 훑지 않으니 쿼리가 작고, 결과 캐시도 잘 맞는다.
--
-- 주의: sling은 이 파일을 세미콜론 단위로 잘라 문장마다 따로 실행한다.
-- 그래서 DECLARE 같은 스크립트 변수를 쓸 수 없고, 주석과 문자열 안에 세미콜론을 쓰면 안 된다.
-- 모든 문장은 다시 실행해도 결과가 같도록(멱등) 작성한다.
--
-- 날짜는 모두 KST 기준이다.

CREATE SCHEMA IF NOT EXISTS `snutt-792f1.snutt_metrics` OPTIONS (location = 'US');

-- =====================================================================
-- 1. GA4(Firebase) 앱 이벤트 → 기기·날짜별 한 줄
-- =====================================================================
-- 대시보드가 GA 원본(이벤트 한 건당 한 줄, 하루 수십 MB)을 직접 읽으면 패널마다 몇 GB씩 읽게 된다.
-- 그래서 필요한 값만 기기(user_pseudo_id)·날짜별 한 줄로 줄여 둔다. 매일 전체를 다시 만든다.
-- GA는 늦게 들어온 이벤트로 최근 며칠 테이블을 다시 쓰는데, 전체를 다시 만드니 따로 처리할 필요가 없다.
CREATE OR REPLACE TABLE `snutt-792f1.snutt_metrics.ga_user_day`
PARTITION BY date
CLUSTER BY platform
AS
SELECT
  PARSE_DATE('%Y%m%d', event_date) AS date,
  user_pseudo_id,
  ANY_VALUE(platform) AS platform,
  ARRAY_AGG(app_info.version IGNORE NULLS ORDER BY event_timestamp DESC LIMIT 1)[SAFE_OFFSET(0)] AS app_version,
  -- 앱을 실제로 열었는지 (session_start, screen_view, user_engagement 중 하나)
  LOGICAL_OR(event_name IN ('session_start', 'screen_view', 'user_engagement')) AS is_active,
  -- 설치 후 첫 실행
  LOGICAL_OR(event_name = 'first_open') AS first_open,
  -- 앱 삭제. Android만 수집된다
  LOGICAL_OR(event_name = 'app_remove') AS app_remove,
  COUNTIF(event_name = 'session_start') AS sessions,
  -- 앱이 화면에 떠 있던 시간(초)
  IFNULL(SUM((SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'engagement_time_msec')), 0) / 1000 AS engagement_sec,
  COUNTIF(event_name = 'add_to_timetable') AS add_to_timetable,
  COUNTIF(event_name = 'search_lecture') AS search_lecture,
  COUNTIF(event_name = 'lecture_detail') AS lecture_detail,
  COUNTIF(event_name = 'review_detail') AS review_detail,
  COUNTIF(event_name = 'add_to_bookmark') AS add_to_bookmark,
  COUNTIF(event_name = 'add_to_vacancy') AS add_to_vacancy,
  COUNTIF(event_name = 'notification_open') AS notification_open,
  -- 친구 화면 조회. iOS만 화면 이름이 남는다(Android는 난독화돼 있다)
  COUNTIF(event_name = 'screen_view' AND (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'firebase_screen') = 'friends') AS friends_view
FROM `snutt-792f1.analytics_151365831.events_*`
-- events_intraday_* (실시간 export)는 제외한다
WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^[0-9]{8}$')
  AND user_pseudo_id IS NOT NULL
GROUP BY date, user_pseudo_id;

-- 날짜·플랫폼별 앱 지표
CREATE OR REPLACE VIEW `snutt-792f1.snutt_metrics.ga_daily` AS
SELECT
  date,
  platform,
  COUNTIF(is_active) AS dau,
  COUNTIF(first_open) AS installs,
  COUNTIF(app_remove) AS uninstalls,
  SUM(sessions) AS sessions,
  SUM(IF(is_active, engagement_sec, 0)) AS engagement_sec,
  SUM(add_to_timetable) AS add_to_timetable,
  SUM(search_lecture) AS search_lecture,
  SUM(lecture_detail) AS lecture_detail,
  SUM(review_detail) AS review_detail,
  SUM(add_to_bookmark) AS add_to_bookmark,
  SUM(add_to_vacancy) AS add_to_vacancy,
  SUM(notification_open) AS notification_open,
  COUNTIF(is_active AND friends_view > 0) AS friends_viewers
FROM `snutt-792f1.snutt_metrics.ga_user_day`
GROUP BY date, platform;

-- 날짜별 DAU, WAU(그날 포함 7일), MAU(그날 포함 30일). 기기 수 기준이다.
-- 한 사람이 iOS와 Android를 같이 쓰거나 재설치하면 두 번 센다.
CREATE OR REPLACE VIEW `snutt-792f1.snutt_metrics.ga_active_users` AS
WITH active AS (
  SELECT DISTINCT date, user_pseudo_id
  FROM `snutt-792f1.snutt_metrics.ga_user_day`
  WHERE is_active
),
days AS (
  SELECT DISTINCT date FROM active
)
SELECT
  d.date,
  COUNT(DISTINCT IF(a.date = d.date, a.user_pseudo_id, NULL)) AS dau,
  COUNT(DISTINCT IF(a.date > DATE_SUB(d.date, INTERVAL 7 DAY), a.user_pseudo_id, NULL)) AS wau,
  COUNT(DISTINCT a.user_pseudo_id) AS mau,
  -- GA 데이터가 시작된 날(2026-09-17)로부터 30일이 안 지난 날은 MAU가 작게 나온다
  DATE_DIFF(d.date, (SELECT MIN(date) FROM days), DAY) >= 29 AS mau_complete
FROM days AS d
JOIN active AS a
  ON a.date BETWEEN DATE_SUB(d.date, INTERVAL 29 DAY) AND d.date
GROUP BY d.date;

-- 주간 설치 cohort 리텐션. 설치(first_open)한 주를 W0으로 두고, N주 뒤에 앱을 연 기기 비율.
-- 아직 오지 않은 주는 NULL이다.
CREATE OR REPLACE VIEW `snutt-792f1.snutt_metrics.ga_retention_weekly` AS
WITH cohort AS (
  SELECT user_pseudo_id, DATE_TRUNC(MIN(date), WEEK(MONDAY)) AS cohort_week
  FROM `snutt-792f1.snutt_metrics.ga_user_day`
  WHERE first_open
  GROUP BY user_pseudo_id
),
activity AS (
  SELECT DISTINCT user_pseudo_id, DATE_TRUNC(date, WEEK(MONDAY)) AS week
  FROM `snutt-792f1.snutt_metrics.ga_user_day`
  WHERE is_active
),
last_day AS (
  SELECT MAX(date) AS date FROM `snutt-792f1.snutt_metrics.ga_user_day`
),
counts AS (
  SELECT
    c.cohort_week,
    DATE_DIFF(a.week, c.cohort_week, WEEK(MONDAY)) AS week_n,
    COUNT(DISTINCT a.user_pseudo_id) AS users
  FROM cohort AS c
  JOIN activity AS a ON a.user_pseudo_id = c.user_pseudo_id AND a.week >= c.cohort_week
  GROUP BY 1, 2
),
sizes AS (
  SELECT cohort_week, COUNT(*) AS installs FROM cohort GROUP BY 1
)
SELECT
  s.cohort_week,
  s.installs,
  -- N주차(월~일)가 데이터상 끝났을 때만 비율을 낸다
  IF(DATE_ADD(s.cohort_week, INTERVAL 2 WEEK) <= DATE_ADD(l.date, INTERVAL 1 DAY), SAFE_DIVIDE(MAX(IF(c.week_n = 1, c.users, NULL)), s.installs), NULL) AS w1,
  IF(DATE_ADD(s.cohort_week, INTERVAL 3 WEEK) <= DATE_ADD(l.date, INTERVAL 1 DAY), SAFE_DIVIDE(MAX(IF(c.week_n = 2, c.users, NULL)), s.installs), NULL) AS w2,
  IF(DATE_ADD(s.cohort_week, INTERVAL 4 WEEK) <= DATE_ADD(l.date, INTERVAL 1 DAY), SAFE_DIVIDE(MAX(IF(c.week_n = 3, c.users, NULL)), s.installs), NULL) AS w3,
  IF(DATE_ADD(s.cohort_week, INTERVAL 5 WEEK) <= DATE_ADD(l.date, INTERVAL 1 DAY), SAFE_DIVIDE(MAX(IF(c.week_n = 4, c.users, NULL)), s.installs), NULL) AS w4,
  IF(DATE_ADD(s.cohort_week, INTERVAL 7 WEEK) <= DATE_ADD(l.date, INTERVAL 1 DAY), SAFE_DIVIDE(MAX(IF(c.week_n = 6, c.users, NULL)), s.installs), NULL) AS w6,
  IF(DATE_ADD(s.cohort_week, INTERVAL 9 WEEK) <= DATE_ADD(l.date, INTERVAL 1 DAY), SAFE_DIVIDE(MAX(IF(c.week_n = 8, c.users, NULL)), s.installs), NULL) AS w8
FROM sizes AS s
CROSS JOIN last_day AS l
LEFT JOIN counts AS c ON c.cohort_week = s.cohort_week
GROUP BY s.cohort_week, s.installs, l.date;

-- 설치일별 D1, D7, D30 리텐션 (설치 후 N일째에 앱을 연 기기 비율)
CREATE OR REPLACE VIEW `snutt-792f1.snutt_metrics.ga_retention_daily` AS
WITH cohort AS (
  SELECT user_pseudo_id, MIN(date) AS install_date
  FROM `snutt-792f1.snutt_metrics.ga_user_day`
  WHERE first_open
  GROUP BY user_pseudo_id
),
last_day AS (
  SELECT MAX(date) AS date FROM `snutt-792f1.snutt_metrics.ga_user_day`
)
SELECT
  c.install_date,
  COUNT(DISTINCT c.user_pseudo_id) AS installs,
  IF(DATE_ADD(c.install_date, INTERVAL 1 DAY) <= l.date, COUNT(DISTINCT IF(DATE_DIFF(a.date, c.install_date, DAY) = 1, c.user_pseudo_id, NULL)) / COUNT(DISTINCT c.user_pseudo_id), NULL) AS d1,
  IF(DATE_ADD(c.install_date, INTERVAL 7 DAY) <= l.date, COUNT(DISTINCT IF(DATE_DIFF(a.date, c.install_date, DAY) = 7, c.user_pseudo_id, NULL)) / COUNT(DISTINCT c.user_pseudo_id), NULL) AS d7,
  IF(DATE_ADD(c.install_date, INTERVAL 30 DAY) <= l.date, COUNT(DISTINCT IF(DATE_DIFF(a.date, c.install_date, DAY) = 30, c.user_pseudo_id, NULL)) / COUNT(DISTINCT c.user_pseudo_id), NULL) AS d30
FROM cohort AS c
CROSS JOIN last_day AS l
LEFT JOIN `snutt-792f1.snutt_metrics.ga_user_day` AS a
  ON a.user_pseudo_id = c.user_pseudo_id AND a.is_active AND a.date BETWEEN DATE_ADD(c.install_date, INTERVAL 1 DAY) AND DATE_ADD(c.install_date, INTERVAL 30 DAY)
GROUP BY c.install_date, l.date;

-- =====================================================================
-- 2. 서버 데이터(snutt.* 계약 view) → 날짜·학기별 집계
-- =====================================================================
-- 날짜별 신규 건수. 원본 행의 생성 시각으로 센다. 지워진 행은 원본에 없으므로 빠진다.
-- timetable_lectures_added는 지금도 시간표에 남아 있는 강의만 센다(넣었다가 뺀 강의는 원본에 없다).
CREATE OR REPLACE TABLE `snutt-792f1.snutt_metrics.server_daily` AS
SELECT
  date,
  SUM(signups) AS signups,
  SUM(signups_active) AS signups_active,
  SUM(timetables_created) AS timetables_created,
  SUM(timetable_lectures_added) AS timetable_lectures_added,
  SUM(evaluations) AS evaluations,
  SUM(evaluation_likes) AS evaluation_likes
FROM (
  SELECT DATE(created_at, 'Asia/Seoul') AS date, 1 AS signups, IF(active, 1, 0) AS signups_active, 0 AS timetables_created, 0 AS timetable_lectures_added, 0 AS evaluations, 0 AS evaluation_likes
  FROM `snutt-792f1.snutt.user`
  UNION ALL
  SELECT DATE(created_at, 'Asia/Seoul'), 0, 0, 1, 0, 0, 0 FROM `snutt-792f1.snutt.timetable`
  UNION ALL
  SELECT DATE(created_at, 'Asia/Seoul'), 0, 0, 0, 1, 0, 0 FROM `snutt-792f1.snutt.timetable_lecture`
  UNION ALL
  -- from_snuev는 옛 SNUEV에서 옮겨 온 강의평이라 작성 수에서 뺀다
  SELECT DATE(created_at, 'Asia/Seoul'), 0, 0, 0, 0, 1, 0 FROM `snutt-792f1.snutt.evaluation` WHERE NOT from_snuev
  UNION ALL
  SELECT DATE(created_at, 'Asia/Seoul'), 0, 0, 0, 0, 0, 1 FROM `snutt-792f1.snutt.evaluation_like`
)
WHERE date IS NOT NULL
GROUP BY date;

-- 학기별 시간표·강의평 현황 (현재 상태 기준)
-- semester: 1=1학기, 2=여름학기, 3=2학기, 4=겨울학기
CREATE OR REPLACE TABLE `snutt-792f1.snutt_metrics.semester_stats` AS
WITH tt AS (
  SELECT
    t.year,
    t.semester,
    COUNT(*) AS timetables,
    COUNT(DISTINCT t.user_id) AS users_with_timetable,
    COUNTIF(t.is_primary) AS primary_timetables
  FROM `snutt-792f1.snutt.timetable` AS t
  WHERE t.year IS NOT NULL
  GROUP BY 1, 2
),
primary_lectures AS (
  SELECT t.year, t.semester, AVG(n) AS avg_lectures_per_primary, AVG(credits) AS avg_credits_per_primary
  FROM `snutt-792f1.snutt.timetable` AS t
  JOIN (
    SELECT timetable_id, COUNT(*) AS n, SUM(IFNULL(credit, 0)) AS credits
    FROM `snutt-792f1.snutt.timetable_lecture`
    GROUP BY timetable_id
  ) AS l ON l.timetable_id = t.id
  WHERE t.is_primary
  GROUP BY 1, 2
),
ev AS (
  SELECT year, semester, COUNTIF(NOT from_snuev) AS evaluations, COUNT(DISTINCT IF(NOT from_snuev, user_id, NULL)) AS evaluation_authors
  FROM `snutt-792f1.snutt.evaluation`
  WHERE year IS NOT NULL
  GROUP BY 1, 2
)
SELECT
  year,
  semester,
  FORMAT('%d-%s', year, CASE semester WHEN 1 THEN '1' WHEN 2 THEN 'S' WHEN 3 THEN '2' WHEN 4 THEN 'W' ELSE CAST(semester AS STRING) END) AS label,
  IFNULL(tt.timetables, 0) AS timetables,
  IFNULL(tt.users_with_timetable, 0) AS users_with_timetable,
  IFNULL(tt.primary_timetables, 0) AS primary_timetables,
  pl.avg_lectures_per_primary,
  pl.avg_credits_per_primary,
  IFNULL(ev.evaluations, 0) AS evaluations,
  IFNULL(ev.evaluation_authors, 0) AS evaluation_authors
FROM tt
FULL JOIN ev USING (year, semester)
LEFT JOIN primary_lectures AS pl USING (year, semester);

-- =====================================================================
-- 3. 친구
-- =====================================================================
-- 날짜별 친구 요청 수. 요청 시각(created_at)으로 센다.
-- 거절하거나 끊은 관계는 원본에 없으므로 빠진다. 그래서 지금 남아 있는 관계 기준이다.
CREATE OR REPLACE TABLE `snutt-792f1.snutt_metrics.friend_daily` AS
SELECT
  DATE(created_at, 'Asia/Seoul') AS date,
  COUNT(*) AS requests,
  COUNTIF(is_accepted) AS accepted,
  COUNTIF(NOT is_accepted) AS pending
FROM `snutt-792f1.snutt.friend`
WHERE created_at IS NOT NULL
GROUP BY date;

-- 탈퇴하지 않은 사용자별 친구 수(수락된 관계만)를 구간으로 나눈 분포. 친구가 0명인 사용자도 센다.
CREATE OR REPLACE TABLE `snutt-792f1.snutt_metrics.friend_count_dist` AS
WITH edges AS (
  SELECT from_user_id AS user_id FROM `snutt-792f1.snutt.friend` WHERE is_accepted
  UNION ALL
  SELECT to_user_id FROM `snutt-792f1.snutt.friend` WHERE is_accepted
),
per_user AS (
  SELECT u.id, COUNT(e.user_id) AS friends
  FROM `snutt-792f1.snutt.user` AS u
  LEFT JOIN edges AS e ON e.user_id = u.id
  WHERE u.active
  GROUP BY u.id
)
SELECT
  CASE WHEN friends = 0 THEN 0 WHEN friends = 1 THEN 1 WHEN friends <= 4 THEN 2 WHEN friends <= 9 THEN 3 ELSE 4 END AS bucket_order,
  CASE WHEN friends = 0 THEN '0명' WHEN friends = 1 THEN '1명' WHEN friends <= 4 THEN '2~4명' WHEN friends <= 9 THEN '5~9명' ELSE '10명 이상' END AS bucket,
  COUNT(*) AS users
FROM per_user
GROUP BY 1, 2;

-- 지금 상태 요약 (한 줄)
CREATE OR REPLACE TABLE `snutt-792f1.snutt_metrics.friend_summary` AS
SELECT
  COUNTIF(is_accepted) AS friendships,
  COUNTIF(NOT is_accepted) AS pending_requests,
  (SELECT SUM(users) FROM `snutt-792f1.snutt_metrics.friend_count_dist` WHERE bucket_order > 0) AS users_with_friend,
  (SELECT SUM(users) FROM `snutt-792f1.snutt_metrics.friend_count_dist`) AS active_users
FROM `snutt-792f1.snutt.friend`;
