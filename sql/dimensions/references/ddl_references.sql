CREATE TABLE IF NOT EXISTS `{project_id}.{dataset_id}.references` (
    environment	STRING  not null    OPTIONS(description="gcp environment"),
    project_id	STRING  not null       OPTIONS(description="gcp project id"),
    dataset_id	STRING   not null   OPTIONS(description="gcp dataset id"),
    table_name	STRING   not null   OPTIONS(description="gcp table id"),
    table_type	STRING   not null   OPTIONS(description="gcp table type, e.g. table, view"),
    creation_time	TIMESTAMP   not null   OPTIONS(description="gcp table creation time"),
    last_modified_time	TIMESTAMP   not null   OPTIONS(description="gcp table last modification time"),
    row_count	INTEGER   not null   OPTIONS(description="gcp table number of rows"),
    table_size_gb	FLOAT64   not null   OPTIONS(description="gcp table size in gigs"),
    table_options   STRUCT<label STRUCT<label_object STRUCT<name STRING, value STRING>>, option STRUCT<name STRING, value STRING>>    OPTIONS(description="table options"),
    columns   STRUCT<column_name	STRING, data_type	STRING, column_description	STRING >    OPTIONS(description="list of columns, data types and column descriptions")
    );
