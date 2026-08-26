WITH cw AS (
    SELECT
        (SELECT COALESCE(MAX(rds_cpu.__value__),0) FROM rds_cpu) AS rds_cpu,
        (SELECT COALESCE(MIN(rds_mem.__value__),0) FROM rds_mem) AS rds_mem,
        (SELECT COALESCE(MAX(rds_repl_lag.__value__),0) FROM rds_repl_lag) AS rds_repl_lag
)

SELECT CASE

    -- RED CHECKS
    WHEN MAX(cw.rds_cpu) > 90 THEN 2
    WHEN MIN(cw.rds_mem) > 0
         AND MIN(cw.rds_mem) < 536870912 THEN 2
    WHEN MAX(cw.rds_repl_lag) > 10000 THEN 2

    -- AMBER CHECKS
    WHEN MAX(cw.rds_cpu) BETWEEN 75 AND 90 THEN 1
    WHEN MIN(cw.rds_mem) BETWEEN 536870912 AND 1073741824 THEN 1
    WHEN MAX(cw.rds_repl_lag) BETWEEN 5000 AND 10000 THEN 1

    ELSE 0

END AS rds_health

FROM cw


(SELECT COALESCE(MAX(rds_cpu.__value__),0) FROM rds_cpu) AS rds_cpu,
(SELECT COALESCE(MIN(rds_mem.__value__),0) FROM rds_mem) AS rds_mem,
(SELECT COALESCE(MAX(rds_repl_lag.__value__),0) FROM rds_repl_lag) AS rds_repl_lag



WHEN MAX(cw.rds_cpu) > 90 THEN 2
WHEN MIN(cw.rds_mem) > 0 AND MIN(cw.rds_mem) < 536870912 THEN 2
WHEN MAX(cw.rds_repl_lag) > 10000 THEN 2


WHEN MAX(cw.rds_cpu) BETWEEN 75 AND 90 THEN 1
WHEN MIN(cw.rds_mem) BETWEEN 536870912 AND 1073741824 THEN 1
WHEN MAX(cw.rds_repl_lag) BETWEEN 5000 AND 10000 THEN 1


