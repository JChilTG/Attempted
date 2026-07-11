{{
    config(
        materialized='view',
        schema='staging',
        tags=['staging', 'ga4']
    )
}}

/*
    GA4 events from BigQuery export with extracted event_params.

    Flattens:
    - Nested device, geo, traffic_source objects
    - event_params array -> key-value columns
    - user_properties array -> key-value columns (common ones)

    Common event_params extracted:
    - page_location, page_title, page_referrer (all events)
    - value, currency (ecommerce)
    - search_term (search)
    - method (login)
    - checkout_step, items (ecommerce)
    - engagement_time_msec
    - session_number
*/

WITH raw_events AS (
    SELECT
        -- Basic event info
        CAST(event_date AS DATE)                      AS event_date,
        event_timestamp,
        CAST(event_timestamp / 1000.0 / 1000 / 1000
             AS datetime2(3))                         AS event_datetime,
        event_name,

        -- User & session
        user_id,
        user_pseudo_id,
        session_id,

        -- Device info
        platform,
        device_category,
        device_os,
        device_os_version,
        device_language,
        device_model,
        device_brand,

        -- Geo info
        geo_continent,
        geo_country,
        geo_region,
        geo_city,

        -- Traffic source
        traffic_source_name,
        traffic_source_medium,
        traffic_source_source,

        -- Event params (as JSON if coming from BigQuery)
        event_params,

        -- User properties
        user_properties,

        -- Engagement metrics
        is_session_start,
        engagement_time_msec,

        -- Stream metadata
        stream_id,
        privacy_info_analytics_storage,
        privacy_info_ads_storage,
        privacy_info_uses_transient_token

    FROM {{ source('ga4_bigquery_export', 'events') }}

    WHERE event_date >= CAST(DATEADD(day, -90, GETDATE()) AS DATE)
        AND user_id IS NOT NULL
),

parsed_params AS (
    SELECT
        *,

        -- Extract common event params using JSON_VALUE
        -- Page params (common across all events)
        JSON_VALUE(event_params, '$.page_location.string_value')        AS param_page_location,
        JSON_VALUE(event_params, '$.page_title.string_value')           AS param_page_title,
        JSON_VALUE(event_params, '$.page_referrer.string_value')        AS param_page_referrer,
        JSON_VALUE(event_params, '$.page_path.string_value')            AS param_page_path,

        -- Ecommerce params
        JSON_VALUE(event_params, '$.value.string_value')                AS param_value,
        JSON_VALUE(event_params, '$.value.double_value')                AS param_value_numeric,
        JSON_VALUE(event_params, '$.currency.string_value')             AS param_currency,
        JSON_VALUE(event_params, '$.items.string_value')                AS param_items,

        -- Search
        JSON_VALUE(event_params, '$.search_term.string_value')          AS param_search_term,

        -- Auth
        JSON_VALUE(event_params, '$.method.string_value')               AS param_auth_method,

        -- User engagement
        JSON_VALUE(event_params, '$.session_number.int_value')          AS param_session_number,
        JSON_VALUE(event_params, '$.engagement_time_msec.int_value')    AS param_engagement_time_msec,

        -- Video
        JSON_VALUE(event_params, '$.video_title.string_value')          AS param_video_title,
        JSON_VALUE(event_params, '$.video_duration.int_value')          AS param_video_duration,
        JSON_VALUE(event_params, '$.video_current_time.int_value')      AS param_video_current_time,

        -- Ecommerce checkout
        JSON_VALUE(event_params, '$.checkout_step.int_value')           AS param_checkout_step,
        JSON_VALUE(event_params, '$.coupon.string_value')               AS param_coupon,

        -- Extract user properties
        JSON_VALUE(user_properties, '$.first_open_timestamp.int_value') AS user_first_open_timestamp,
        JSON_VALUE(user_properties, '$.user_ltv.currency_value')        AS user_ltv_currency,
        JSON_VALUE(user_properties, '$.user_ltv.string_value')          AS user_ltv_value

    FROM raw_events
)

SELECT
    event_date,
    event_datetime,
    event_timestamp,
    event_name,
    user_id,
    user_pseudo_id,
    session_id,
    platform,
    device_category,
    device_os,
    device_os_version,
    device_language,
    device_model,
    device_brand,
    geo_continent,
    geo_country,
    geo_region,
    geo_city,
    traffic_source_name,
    traffic_source_medium,
    traffic_source_source,
    is_session_start,
    engagement_time_msec,
    stream_id,
    privacy_info_analytics_storage,
    privacy_info_ads_storage,
    privacy_info_uses_transient_token,

    -- Extracted event params
    param_page_location,
    param_page_title,
    param_page_referrer,
    param_page_path,
    param_value,
    CAST(param_value_numeric AS float)               AS param_value_numeric,
    param_currency,
    param_items,
    param_search_term,
    param_auth_method,
    CAST(param_session_number AS int)                AS param_session_number,
    CAST(param_engagement_time_msec AS int)          AS param_engagement_time_msec,
    param_video_title,
    CAST(param_video_duration AS int)                AS param_video_duration,
    CAST(param_video_current_time AS int)            AS param_video_current_time,
    CAST(param_checkout_step AS int)                 AS param_checkout_step,
    param_coupon,
    CAST(user_first_open_timestamp AS bigint)        AS user_first_open_timestamp,
    user_ltv_currency,
    user_ltv_value,

    -- Metadata
    ROW_NUMBER() OVER (
        PARTITION BY user_id, session_id
        ORDER BY event_timestamp
    )                                                 AS event_sequence_in_session,

    CAST(HASHBYTES('MD5', CONCAT(
        CAST(user_id AS nvarchar(400)), '||',
        CAST(session_id AS nvarchar(400)), '||',
        CAST(event_timestamp AS nvarchar(400))
    )) AS varchar(64))                               AS event_hash,

    CAST(GETDATE() AS DATE)                          AS extract_date

FROM parsed_params

ORDER BY user_id, session_id, event_timestamp
