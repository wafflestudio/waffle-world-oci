-- 대시보드가 조회하는 계약 view. 컬럼 이름과 의미는 snutt v2 MySQL 스키마를 따른다.
-- v1(Mongo) 원본은 snutt_raw_v1에 있고, v2 전환 시 이 파일의 FROM 절과 변환식만 바꾼다.
-- 변환 규칙은 snutt-v2 migration 모듈(UserStep, TimetableStep)과 같다.
-- id는 v1 ObjectId(hex)와 v2 BIGINT를 모두 담을 수 있도록 STRING으로 둔다.

CREATE SCHEMA IF NOT EXISTS `snutt-792f1.snutt` OPTIONS (location = 'US');

CREATE OR REPLACE VIEW `snutt-792f1.snutt.user` AS
SELECT
  _id AS id,
  IF(STRPOS(nickname, '#') > 0, REGEXP_EXTRACT(nickname, r'^(.*)#'), nickname) AS nickname,
  IF(STRPOS(nickname, '#') > 0, REGEXP_EXTRACT(nickname, r'#([^#]*)$'), nickname) AS nickname_tag,
  IFNULL(isEmailVerified, FALSE) AS is_email_verified,
  IFNULL(active, FALSE) AS active,
  IFNULL(isAdmin, FALSE) AS is_admin,
  IFNULL(has_local, FALSE) AS has_local_login,
  IFNULL(has_apple, FALSE) AS has_apple_login,
  IFNULL(has_google, FALSE) AS has_google_login,
  IFNULL(has_kakao, FALSE) AS has_kakao_login,
  IFNULL(has_facebook, FALSE) AS has_facebook_login,
  COALESCE(TIMESTAMP_MILLIS(lastLoginTimestamp), regDate) AS last_login_at,
  notificationCheckedAt AS notification_checked_at,
  regDate AS created_at
FROM `snutt-792f1.snutt_raw_v1.users`;

-- v1 시간표 문서에는 생성 시각 필드가 없다. Mongo ObjectId의 앞 4바이트가 생성 시각(초)이므로
-- _id에서 꺼내고, ObjectId가 아니면 updated_at을 쓴다. (migration은 updated_at을 쓴다)
CREATE OR REPLACE VIEW `snutt-792f1.snutt.timetable` AS
SELECT
  _id AS id,
  user_id,
  year,
  semester,
  title,
  IFNULL(is_primary, FALSE) AS is_primary,
  COALESCE(TIMESTAMP_SECONDS(SAFE_CAST(CONCAT('0x', SUBSTR(_id, 1, 8)) AS INT64)), updated_at) AS created_at,
  updated_at
FROM `snutt-792f1.snutt_raw_v1.timetables`;

-- lecture_id가 NULL이면 사용자가 직접 만든 강의다.
-- 강의 항목 _id도 ObjectId라 추가된 시각을 담는다. 시간표를 복사하면 강의 _id는 원본 것을 유지하므로
-- 시간표 생성 시각보다 이르면 시간표 생성 시각을 쓴다.
CREATE OR REPLACE VIEW `snutt-792f1.snutt.timetable_lecture` AS
SELECT
  JSON_VALUE(lecture, '$._id') AS id,
  t._id AS timetable_id,
  JSON_VALUE(lecture, '$.lecture_id') AS lecture_id,
  JSON_VALUE(lecture, '$.course_title') AS course_title,
  SAFE_CAST(JSON_VALUE(lecture, '$.credit') AS INT64) AS credit,
  GREATEST(
    COALESCE(TIMESTAMP_SECONDS(SAFE_CAST(CONCAT('0x', SUBSTR(JSON_VALUE(lecture, '$._id'), 1, 8)) AS INT64)), t.created_at),
    t.created_at
  ) AS created_at
FROM (
  SELECT
    _id,
    lecture_list,
    COALESCE(TIMESTAMP_SECONDS(SAFE_CAST(CONCAT('0x', SUBSTR(_id, 1, 8)) AS INT64)), updated_at) AS created_at
  FROM `snutt-792f1.snutt_raw_v1.timetables`
) AS t,
  UNNEST(JSON_QUERY_ARRAY(t.lecture_list)) AS lecture;

-- 강의평(snutt-ev). v2의 course는 v1 ev의 lecture(과목번호+교수)에 해당한다.
-- v2 migration은 중복 과목을 합치므로(courseIdRemap) v1 구간의 course id는 v2와 일부 다를 수 있다.
CREATE OR REPLACE VIEW `snutt-792f1.snutt.course` AS
SELECT
  CAST(id AS STRING) AS id,
  course_number,
  instructor,
  title,
  created_at
FROM `snutt-792f1.snutt_raw_v1.ev_lecture`;

-- user_id는 v1 사용자 ObjectId라 snutt.user.id와 조인된다. 본문은 글자 수(content_length)만 있다.
CREATE OR REPLACE VIEW `snutt-792f1.snutt.evaluation` AS
SELECT
  CAST(e.id AS STRING) AS id,
  CAST(sl.lecture_id AS STRING) AS course_id,
  e.user_id,
  sl.year,
  sl.semester,
  e.content_length,
  e.grade_satisfaction,
  e.teaching_skill,
  e.gains,
  e.life_balance,
  e.rating,
  e.like_count,
  e.is_hidden,
  e.is_reported,
  e.from_snuev,
  e.created_at,
  COALESCE(e.updated_at, e.created_at) AS updated_at
FROM `snutt-792f1.snutt_raw_v1.ev_lecture_evaluation` AS e
JOIN `snutt-792f1.snutt_raw_v1.ev_semester_lecture` AS sl ON sl.id = e.semester_lecture_id;

CREATE OR REPLACE VIEW `snutt-792f1.snutt.evaluation_like` AS
SELECT
  CAST(id AS STRING) AS id,
  CAST(lecture_evaluation_id AS STRING) AS evaluation_id,
  user_id,
  created_at
FROM `snutt-792f1.snutt_raw_v1.ev_evaluation_like`;
