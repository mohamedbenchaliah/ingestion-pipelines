SELECT
    cast ( FORMAT_DATE("%Y%m%d", date_gen  ) as INT64 ) AS dim_date_id,
    date_gen as dim_date,
    UNIX_DATE( date_gen) AS epoch,
    CAST(FORMAT_DATE("%u", date_gen) AS INT64) AS day_of_week,
    EXTRACT(DAY FROM date_gen) AS day_of_month,
    EXTRACT(DAYOFYEAR FROM date_gen) AS day_of_year,
    EXTRACT(WEEK FROM date_gen) AS week_of_year,
    EXTRACT(MONTH FROM date_gen) AS month_of_year,
    FORMAT_DATE("%B", date_gen  )  AS month_name,
    FORMAT_DATE("%b", date_gen  )  AS month_name_abbreviated,
    FORMAT_DATE("%A", date_gen  )  AS day_name,
    FORMAT_DATE("%a", date_gen  )  AS day_name_abbreviated,
    EXTRACT(QUARTER FROM date_gen) AS quarter_of_year,
    CASE
       WHEN EXTRACT(QUARTER FROM date_gen) = 1 THEN 'First'
       WHEN EXTRACT(QUARTER FROM date_gen) = 2 THEN 'Second'
       WHEN EXTRACT(QUARTER FROM date_gen) = 3 THEN 'Third'
       WHEN EXTRACT(QUARTER FROM date_gen) = 4 THEN 'Fourth'
       END AS quarter_name,
    EXTRACT(ISOYEAR FROM date_gen) AS dim_year,
    DATE_TRUNC(date_gen,MONTH)  AS first_day_of_month,
    DATE_SUB (
             DATE_TRUNC (  DATE_ADD ( DATE_TRUNC( date_gen,MONTH), interval 32 DAY) ,MONTH)
             , interval 1           DAY
             )
          AS last_day_of_month,
    DATE_TRUNC( date_gen, quarter)  AS first_day_of_quarter,
    DATE_SUB (
        DATE_TRUNC( DATE_ADD (DATE_TRUNC( date_gen, quarter), interval 95 DAY) ,MONTH)
          , interval 1           DAY
        )
       AS last_day_of_quarter,
    CAST(EXTRACT(YEAR FROM date_gen) || '-01-01' AS DATE) AS first_day_of_year,
    CAST(EXTRACT(YEAR FROM date_gen) || '-12-31' AS DATE)  AS last_day_of_year,
    FORMAT_DATE("%Y%m", date_gen  ) AS yyyymm,
    CASE
       WHEN EXTRACT(DAYOFWEEK FROM date_gen) IN (6, 7) THEN TRUE
       ELSE FALSE
       END AS weekend_indr
FROM (SELECT
     x as date_gen
      FROM UNNEST(GENERATE_DATE_ARRAY('2022-01-01', '2199-12-31') ) AS x
    ) TimeD;