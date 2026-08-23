cw AS (
  SELECT
    (SELECT COALESCE(MAX(apigw_4xx.__value__),0) FROM apigw_4xx) AS apigw_4xx,
    (SELECT COALESCE(MAX(apigw_5xx.__value__),0) FROM apigw_5xx) AS apigw_5xx,
    (SELECT COALESCE(MAX(apigw_latency.__value__),0) FROM apigw_latency) AS apigw_latency,
    (SELECT COALESCE(MAX(apigw_cnt.__value__),0) FROM apigw_cnt) AS apigw_cnt,

    (
      COALESCE((SELECT MAX(apigw_hit_fla.__value__) FROM apigw_hit_fla), 0)
      +
      COALESCE((SELECT MAX(apigw_hit_flw.__value__) FROM apigw_hit_flw), 0)
    ) AS apigw_h,

    (
      COALESCE((SELECT MAX(apigw_miss_fla.__value__) FROM apigw_miss_fla), 0)
      +
      COALESCE((SELECT MAX(apigw_miss_flw.__value__) FROM apigw_miss_flw), 0)
    ) AS apigw_m
)