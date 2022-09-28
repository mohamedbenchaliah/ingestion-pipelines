create table if not exists `c4-gdw-dev.pss_dataset.gdw_tables_auditing`(
     comparison_date    DATETIME                    OPTIONS(description="comparison batch time"),
     source_table       STRING                      OPTIONS(description="source table (left table)"),
     target_table       STRING                      OPTIONS(description="compare table (right table)"),

     column_summary  STRUCT<
         number_of_columns_in_common_with_matching_schema  INT64,
         number_of_columns_in_common_with_schema_differences  INT64,
         number_of_columns_in_source_but_not_in_target  INT64,
         number_of_columns_in_target_but_not_in_source  INT64
         >      OPTIONS(description="columns check summary"),

     columns_in_source_only  ARRAY<STRUCT<
         column_name  STRING,
         dtype  STRING
         >>     OPTIONS(description="columns in source only summary"),

     columns_in_target_only  ARRAY<STRUCT<
         column_name  STRING,
         dtype  STRING
         >>     OPTIONS(description="columns in target only summary"),

     row_summary  STRUCT<
         number_of_duplicate_rows_found_in_source  INT64,
         number_of_duplicate_rows_found_in_target  INT64,
         number_of_rows_in_source_but_not_in_target  INT64,
         number_of_rows_in_target_but_not_in_source  INT64,
         number_of_rows_in_common  INT64
         >     OPTIONS(description="row check summary"),

     row_comparison  STRUCT<
         number_of_rows_with_all_columns_equal  INT64,
         number_of_rows_with_some_columns_unequal  INT64
         >     OPTIONS(description="row by row comparison"),

     row_match_summary  ARRAY<STRUCT<
         source_column_name  STRING,
         source_dtype  STRING,
         target_column_name  STRING,
         target_dtype  STRING,
         match_rate  FLOAT64,
         number_of_known_diffs  INTEGER,
         number_of_matches  INTEGER,
         number_of_mismatches  INTEGER
         >>     OPTIONS(description="row match summary"),

     schema_differences  ARRAY<STRUCT<
         source_column_name  STRING,
         source_dtype  STRING,
         target_column_name  STRING,
         target_dtype  STRING
         >>     OPTIONS(description="schema differences summary")
)
