/*
PROJECT: Zomato Order Performance Analysis
PURPOSE: Portfolio SQL queries used for data quality checks, platform performance,
         city, restaurant/brand, cuisine, delivery, promotion, cancellation, and growth analysis.
DIALECT: MySQL 8.0+ (uses CTEs, window functions, and JSON_TABLE).

IMPORTANT NOTES
- This script assumes `zomato_orders` and `zomato_restaurants` have already been imported.
- Most analytical queries are read-only. The optional setup and cuisine-bridge sections
  create/update tables; read their comments before executing those statements.
- Analysis cutoff: 2024-09-30, excluding the incomplete 2024-10-01 observation.
- Unless stated otherwise, business-performance analysis includes non-cancelled orders
  (`Delivered` and `In-Transit`) through the cutoff date.
- `restaurant_name`-level rankings aggregate records sharing the same name; they are
  brand/name-level results, not necessarily individual outlet rankings.
- Cuisine-attributed order value can be counted under multiple cuisines when a restaurant
  offers several cuisines. Do not sum cuisine-level order values and expect the platform
  total to reconcile.
*/

/* ============================================================================
   00. OPTIONAL SETUP REFERENCE (commented out; do not run if tables already exist)
   ============================================================================

-- CREATE DATABASE zomato_analysis;
-- USE zomato_analysis;

-- Example Orders table schema used during import:
-- CREATE TABLE zomato_orders (
--     order_id INT,
--     order_amount DECIMAL(10,2),
--     delivery_time DECIMAL(6,2),
--     order_date TEXT,
--     rating DECIMAL(3,1),
--     number_of_items INT,
--     delivery_distance DECIMAL(6,2),
--     delivery_agent_id INT,
--     order_status VARCHAR(30),
--     payment_method VARCHAR(30),
--     tip_amount DECIMAL(10,2),
--     promo_code_applied VARCHAR(10),
--     has_free_delivery VARCHAR(10),
--     res_id INT
-- );

-- Example Restaurants table schema used during import:
-- CREATE TABLE zomato_restaurants (
--     res_id INT,
--     restaurant_name TEXT,
--     restaurant_type TEXT,
--     city VARCHAR(150),
--     locality TEXT,
--     latitude DOUBLE,
--     longitude DOUBLE,
--     cuisines TEXT,
--     average_cost_for_two INT,
--     price_range INT,
--     aggregate_rating DECIMAL(3,1),
--     votes INT
-- );

-- Optional one-time enrichment. These ALTER statements fail if the columns already exist.
-- Analytical queries below calculate year/quarter directly from order_date and do not
-- require these columns.
-- ALTER TABLE zomato_orders ADD COLUMN order_year INT;
-- UPDATE zomato_orders
-- SET order_year = YEAR(STR_TO_DATE(order_date, '%d-%m-%Y'));
-- ALTER TABLE zomato_orders ADD COLUMN order_quarter INT;
-- UPDATE zomato_orders
-- SET order_quarter = QUARTER(STR_TO_DATE(order_date, '%d-%m-%Y'));
*/

/* ============================================================================
   01. INITIAL DATA CHECKS
   ============================================================================ */

-- Total rows and unique orders in the Orders table.
SELECT COUNT(*) AS order_rows,
       COUNT(DISTINCT order_id) AS unique_orders
FROM zomato_orders;

-- Verify order ID range.
SELECT MIN(order_id) AS min_order_id,
       MAX(order_id) AS max_order_id
FROM zomato_orders;

-- Total rows and unique restaurant IDs.
SELECT COUNT(*) AS restaurant_rows,
       COUNT(DISTINCT res_id) AS unique_restaurants
FROM zomato_restaurants;

-- Check whether any order has a restaurant ID that is not present in Restaurants.
SELECT COUNT(*) AS unmatched_order_restaurant_rows
FROM zomato_orders AS o
LEFT JOIN zomato_restaurants AS r
    ON o.res_id = r.res_id
WHERE o.res_id IS NOT NULL
  AND r.res_id IS NULL;

-- Inspect a small sample when validating imports.
SELECT *
FROM zomato_orders
LIMIT 2;

SELECT *
FROM zomato_restaurants
LIMIT 5;

/* ============================================================================
   02. PLATFORM PERFORMANCE AND QUARTERLY TRENDS
   ============================================================================ */

-- Non-cancelled orders by year and quarter within the valid analysis period.
SELECT YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) AS order_year,
       QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) AS order_quarter,
       COUNT(DISTINCT o.order_id) AS total_orders
FROM zomato_orders AS o
WHERE o.order_status <> 'Cancelled'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
GROUP BY YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')),
         QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y'))
ORDER BY order_year, order_quarter;

-- Non-cancelled order volume, order value, and AOV by quarter.
SELECT YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) AS order_year,
       QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) AS order_quarter,
       COUNT(DISTINCT o.order_id) AS total_orders,
       SUM(o.order_amount) AS total_order_value,
       ROUND(AVG(o.order_amount), 2) AS average_order_value
FROM zomato_orders AS o
WHERE o.order_status <> 'Cancelled'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
GROUP BY YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')),
         QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y'))
ORDER BY order_year, order_quarter;

-- Quarter-over-quarter growth in non-cancelled order volume and order value.
-- The first quarter has no prior-quarter comparison, so its growth is NULL.
WITH quarterly_summary AS (
    SELECT YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) AS order_year,
           QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) AS order_quarter,
           COUNT(DISTINCT o.order_id) AS total_orders,
           SUM(o.order_amount) AS total_order_value
    FROM zomato_orders AS o
    WHERE o.order_status <> 'Cancelled'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
    GROUP BY YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')),
             QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y'))
),
quarterly_with_previous AS (
    SELECT order_year,
           order_quarter,
           total_orders,
           total_order_value,
           LAG(total_orders) OVER (ORDER BY order_year, order_quarter) AS prev_quarter_orders,
           LAG(total_order_value) OVER (ORDER BY order_year, order_quarter) AS prev_quarter_value
    FROM quarterly_summary
)
SELECT order_year,
       order_quarter,
       total_orders,
       total_order_value,
       prev_quarter_orders,
       prev_quarter_value,
       ROUND(100.0 * (total_orders - prev_quarter_orders) / NULLIF(prev_quarter_orders, 0), 2)
           AS qoq_order_growth_pct,
       ROUND(100.0 * (total_order_value - prev_quarter_value) / NULLIF(prev_quarter_value, 0), 2)
           AS qoq_order_value_growth_pct
FROM quarterly_with_previous
ORDER BY order_year, order_quarter;

/* ============================================================================
   03. CITY PERFORMANCE AND RANKINGS
   ============================================================================ */

-- City-level non-cancelled order volume and order value.
SELECT r.city,
       COUNT(DISTINCT o.order_id) AS order_volume,
       SUM(o.order_amount) AS order_value
FROM zomato_restaurants AS r
JOIN zomato_orders AS o
    ON r.res_id = o.res_id
WHERE o.order_status <> 'Cancelled'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
GROUP BY r.city
ORDER BY order_volume DESC, order_value DESC;

-- Top 5 cities by non-cancelled order volume.
SELECT r.city,
       COUNT(DISTINCT o.order_id) AS city_order_volume,
       ROUND(AVG(o.order_amount), 2) AS aov
FROM zomato_restaurants AS r
JOIN zomato_orders AS o
    ON r.res_id = o.res_id
WHERE o.order_status <> 'Cancelled'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
GROUP BY r.city
ORDER BY city_order_volume DESC
LIMIT 5;

-- Top 5 cities by non-cancelled order value.
SELECT r.city,
       SUM(o.order_amount) AS order_value,
       ROUND(AVG(o.order_amount), 2) AS aov
FROM zomato_restaurants AS r
JOIN zomato_orders AS o
    ON r.res_id = o.res_id
WHERE o.order_status <> 'Cancelled'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
GROUP BY r.city
ORDER BY order_value DESC
LIMIT 5;

-- Bottom 5 cities by order value. DENSE_RANK can return more than five rows when tied.
WITH city_rank AS (
    SELECT r.city,
           SUM(o.order_amount) AS order_value,
           ROUND(AVG(o.order_amount), 2) AS aov,
           DENSE_RANK() OVER (ORDER BY SUM(o.order_amount)) AS ranking
    FROM zomato_restaurants AS r
    JOIN zomato_orders AS o
        ON r.res_id = o.res_id
    WHERE o.order_status <> 'Cancelled'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
    GROUP BY r.city
)
SELECT city, order_value, aov
FROM city_rank
WHERE ranking <= 5
ORDER BY ranking, city;

-- Bottom 5 cities by order volume. DENSE_RANK can return more than five rows when tied.
WITH city_rank AS (
    SELECT r.city,
           COUNT(DISTINCT o.order_id) AS order_volume,
           ROUND(AVG(o.order_amount), 2) AS aov,
           DENSE_RANK() OVER (ORDER BY COUNT(DISTINCT o.order_id)) AS ranking
    FROM zomato_restaurants AS r
    JOIN zomato_orders AS o
        ON r.res_id = o.res_id
    WHERE o.order_status <> 'Cancelled'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
    GROUP BY r.city
)
SELECT city, order_volume, aov
FROM city_rank
WHERE ranking <= 5
ORDER BY ranking, city;

-- Combined order-volume and order-value share of the five largest cities by order value.
WITH city_summary AS (
    SELECT r.city,
           COUNT(DISTINCT o.order_id) AS city_order_volume,
           SUM(o.order_amount) AS city_order_value
    FROM zomato_restaurants AS r
    JOIN zomato_orders AS o
        ON r.res_id = o.res_id
    WHERE o.order_status <> 'Cancelled'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
    GROUP BY r.city
),
city_shares AS (
    SELECT city,
           city_order_volume,
           city_order_value,
           100.0 * city_order_volume / SUM(city_order_volume) OVER () AS order_volume_share_pct,
           100.0 * city_order_value / SUM(city_order_value) OVER () AS order_value_share_pct,
           DENSE_RANK() OVER (ORDER BY city_order_value DESC) AS value_rank
    FROM city_summary
)
SELECT ROUND(SUM(order_volume_share_pct), 2) AS top_5_volume_share_pct,
       ROUND(SUM(order_value_share_pct), 2) AS top_5_value_share_pct
FROM city_shares
WHERE value_rank <= 5;

-- Combined order-volume and order-value share of the five smallest cities by order volume.
WITH city_summary AS (
    SELECT r.city,
           COUNT(DISTINCT o.order_id) AS city_order_volume,
           SUM(o.order_amount) AS city_order_value
    FROM zomato_restaurants AS r
    JOIN zomato_orders AS o
        ON r.res_id = o.res_id
    WHERE o.order_status <> 'Cancelled'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
    GROUP BY r.city
),
city_shares AS (
    SELECT city,
           city_order_volume,
           city_order_value,
           100.0 * city_order_volume / SUM(city_order_volume) OVER () AS order_volume_share_pct,
           100.0 * city_order_value / SUM(city_order_value) OVER () AS order_value_share_pct,
           DENSE_RANK() OVER (ORDER BY city_order_volume) AS volume_rank
    FROM city_summary
)
SELECT ROUND(SUM(order_volume_share_pct), 2) AS bottom_5_volume_share_pct,
       ROUND(SUM(order_value_share_pct), 2) AS bottom_5_value_share_pct
FROM city_shares
WHERE volume_rank <= 5;

/* ============================================================================
   04. RESTAURANT–CUISINE BRIDGE
   ============================================================================
   Run the creation/insertion statements below only if you need to build or rebuild
   the bridge. The INSERT has a NOT EXISTS check to avoid inserting duplicate pairs
   if it is run again. A restaurant may appear under multiple cuisines by design.
   ============================================================================ */

CREATE TABLE IF NOT EXISTS restaurants_cuisines (
    res_id INT NOT NULL,
    cuisine VARCHAR(255) NOT NULL
);

INSERT INTO restaurants_cuisines (res_id, cuisine)
SELECT r.res_id,
       TRIM(j.cuisine) AS cuisine
FROM zomato_restaurants AS r
JOIN JSON_TABLE(
    CONCAT('["', REPLACE(r.cuisines, ',', '","'), '"]'),
    '$[*]' COLUMNS (cuisine VARCHAR(255) PATH '$')
) AS j
WHERE r.cuisines IS NOT NULL
  AND TRIM(r.cuisines) <> ''
  AND TRIM(j.cuisine) <> ''
  AND NOT EXISTS (
      SELECT 1
      FROM restaurants_cuisines AS existing
      WHERE existing.res_id = r.res_id
        AND existing.cuisine = TRIM(j.cuisine)
  );

-- Inspect bridge contents when validating the table.
SELECT *
FROM restaurants_cuisines
LIMIT 20;

-- Check duplicate restaurant–cuisine pairs; expected result is zero rows.
SELECT res_id, cuisine, COUNT(*) AS pair_count
FROM restaurants_cuisines
GROUP BY res_id, cuisine
HAVING COUNT(*) > 1;

-- Cuisine list and number of restaurant–cuisine pairs.
SELECT cuisine,
       COUNT(*) AS restaurant_cuisine_pairs,
       COUNT(DISTINCT res_id) AS restaurants_serving_cuisine
FROM restaurants_cuisines
GROUP BY cuisine
ORDER BY restaurant_cuisine_pairs DESC;

-- One-time correction for a known encoding issue, if the garbled value exists.
UPDATE restaurants_cuisines
SET cuisine = 'Poké'
WHERE cuisine = 'PokÃ©';

/* ============================================================================
   05. RESTAURANT / BRAND PERFORMANCE
   ============================================================================
   These queries group by restaurant_name. Names shared by multiple outlets are
   therefore aggregated together, matching the project's brand/name-level analysis.
   ============================================================================ */

-- Top 10 restaurant names / brands by non-cancelled order volume.
SELECT r.restaurant_name,
       COUNT(DISTINCT o.order_id) AS order_volume,
       SUM(o.order_amount) AS order_value,
       ROUND(AVG(o.order_amount), 2) AS aov
FROM zomato_restaurants AS r
JOIN zomato_orders AS o
    ON r.res_id = o.res_id
WHERE o.order_status <> 'Cancelled'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
GROUP BY r.restaurant_name
ORDER BY order_volume DESC, order_value DESC
LIMIT 10;

-- Top 10 restaurant names / brands by order value, using a CTE and DENSE_RANK.
WITH restaurant_ranking AS (
    SELECT r.restaurant_name,
           SUM(o.order_amount) AS order_value,
           COUNT(DISTINCT o.order_id) AS order_volume,
           ROUND(AVG(o.order_amount), 2) AS aov,
           DENSE_RANK() OVER (ORDER BY SUM(o.order_amount) DESC) AS ranking
    FROM zomato_restaurants AS r
    JOIN zomato_orders AS o
        ON r.res_id = o.res_id
    WHERE o.order_status <> 'Cancelled'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
    GROUP BY r.restaurant_name
)
SELECT restaurant_name, order_volume, order_value, aov, ranking
FROM restaurant_ranking
WHERE ranking <= 10
ORDER BY ranking, restaurant_name;

-- Share of total non-cancelled order value attributed to the top 10 restaurant names / brands.
WITH restaurant_summary AS (
    SELECT r.restaurant_name,
           SUM(o.order_amount) AS order_value
    FROM zomato_restaurants AS r
    JOIN zomato_orders AS o
        ON r.res_id = o.res_id
    WHERE o.order_status <> 'Cancelled'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
    GROUP BY r.restaurant_name
),
restaurant_ranked AS (
    SELECT restaurant_name,
           order_value,
           100.0 * order_value / SUM(order_value) OVER () AS order_value_share_pct,
           DENSE_RANK() OVER (ORDER BY order_value DESC) AS ranking
    FROM restaurant_summary
)
SELECT ROUND(SUM(order_value_share_pct), 2) AS top_10_order_value_share_pct
FROM restaurant_ranked
WHERE ranking <= 10;

-- Alternative cross-check of top 10 share using LIMIT (may differ if there are ties at rank 10).
WITH restaurant_summary AS (
    SELECT r.restaurant_name,
           SUM(o.order_amount) AS order_value
    FROM zomato_restaurants AS r
    JOIN zomato_orders AS o
        ON r.res_id = o.res_id
    WHERE o.order_status <> 'Cancelled'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
    GROUP BY r.restaurant_name
),
top_10 AS (
    SELECT restaurant_name, order_value
    FROM restaurant_summary
    ORDER BY order_value DESC, restaurant_name
    LIMIT 10
)
SELECT ROUND(
           100.0 * SUM(top_10.order_value) /
           (SELECT SUM(order_value) FROM restaurant_summary),
           2
       ) AS top_10_order_value_share_pct_limit
FROM top_10;

/* ============================================================================
   06. CUISINE PERFORMANCE
   ============================================================================ */

-- Top 10 cuisines by non-cancelled order volume.
SELECT c.cuisine,
       COUNT(DISTINCT o.order_id) AS order_volume
FROM restaurants_cuisines AS c
JOIN zomato_orders AS o
    ON c.res_id = o.res_id
WHERE o.order_status <> 'Cancelled'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
GROUP BY c.cuisine
ORDER BY order_volume DESC
LIMIT 10;

-- Top 10 cuisines by cuisine-attributed order value. Ties can return more than 10 rows.
WITH cuisine_summary AS (
    SELECT c.cuisine,
           SUM(o.order_amount) AS cuisine_attributed_order_value,
           DENSE_RANK() OVER (ORDER BY SUM(o.order_amount) DESC) AS ranking
    FROM restaurants_cuisines AS c
    JOIN zomato_orders AS o
        ON c.res_id = o.res_id
    WHERE o.order_status <> 'Cancelled'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
    GROUP BY c.cuisine
)
SELECT cuisine, cuisine_attributed_order_value, ranking
FROM cuisine_summary
WHERE ranking <= 10
ORDER BY ranking, cuisine;

-- Order volume, cuisine-attributed order value, and AOV by cuisine.
-- Order value is attributed to every cuisine associated with a restaurant; cuisine totals overlap.
SELECT c.cuisine,
       COUNT(DISTINCT o.order_id) AS order_volume,
       SUM(o.order_amount) AS cuisine_attributed_order_value,
       ROUND(AVG(o.order_amount), 2) AS aov
FROM restaurants_cuisines AS c
JOIN zomato_orders AS o
    ON c.res_id = o.res_id
WHERE o.order_status <> 'Cancelled'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
GROUP BY c.cuisine
ORDER BY cuisine_attributed_order_value DESC
LIMIT 10;

-- Overall restaurant footprint by cuisine, regardless of order activity.
SELECT c.cuisine,
       COUNT(DISTINCT c.res_id) AS restaurants_serving_cuisine
FROM restaurants_cuisines AS c
GROUP BY c.cuisine
ORDER BY restaurants_serving_cuisine DESC
LIMIT 10;

-- Active restaurants by cuisine, limited to restaurants with qualifying non-cancelled orders.
-- This is not the same denominator as the overall restaurant footprint above.
SELECT c.cuisine,
       COUNT(DISTINCT o.order_id) AS order_volume,
       SUM(o.order_amount) AS cuisine_attributed_order_value,
       COUNT(DISTINCT c.res_id) AS active_restaurants_with_orders,
       ROUND(COUNT(DISTINCT o.order_id) * 1.0 / NULLIF(COUNT(DISTINCT c.res_id), 0), 2)
           AS orders_per_active_restaurant
FROM restaurants_cuisines AS c
JOIN zomato_orders AS o
    ON c.res_id = o.res_id
WHERE o.order_status <> 'Cancelled'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
GROUP BY c.cuisine
ORDER BY active_restaurants_with_orders DESC
LIMIT 10;

/* ============================================================================
   07. DELIVERY PERFORMANCE AND CORRELATION
   ============================================================================ */

-- Overall delivery-time distribution across all rows in the cleaned Orders table.
-- This intentionally has no status/date filter and should not be compared directly with
-- metrics calculated only on non-cancelled orders in the valid analysis period.
SELECT MIN(delivery_time) AS min_delivery_time,
       MAX(delivery_time) AS max_delivery_time,
       ROUND(AVG(delivery_time), 2) AS avg_delivery_time
FROM zomato_orders;

-- Delivery-time bands and average rating for non-cancelled orders in the valid period.
SELECT CASE
           WHEN o.delivery_time BETWEEN 10 AND 19 THEN '10-19'
           WHEN o.delivery_time BETWEEN 20 AND 29 THEN '20-29'
           WHEN o.delivery_time BETWEEN 30 AND 39 THEN '30-39'
           WHEN o.delivery_time BETWEEN 40 AND 49 THEN '40-49'
           WHEN o.delivery_time BETWEEN 50 AND 59 THEN '50-59'
           WHEN o.delivery_time BETWEEN 60 AND 69 THEN '60-69'
           WHEN o.delivery_time BETWEEN 70 AND 79 THEN '70-79'
           WHEN o.delivery_time BETWEEN 80 AND 89 THEN '80-89'
           ELSE 'Outside defined bands'
       END AS delivery_time_band,
       COUNT(*) AS order_count,
       ROUND(AVG(o.rating), 2) AS average_rating
FROM zomato_orders AS o
WHERE o.order_status <> 'Cancelled'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
  AND o.delivery_time IS NOT NULL
GROUP BY delivery_time_band
ORDER BY MIN(o.delivery_time);

-- Pearson correlation: delivery time vs rating (non-cancelled orders in the valid period).
SELECT (
           COUNT(*) * SUM(o.delivery_time * o.rating)
           - SUM(o.delivery_time) * SUM(o.rating)
       ) /
       NULLIF(
           SQRT(
               (COUNT(*) * SUM(o.delivery_time * o.delivery_time) - POW(SUM(o.delivery_time), 2))
               *
               (COUNT(*) * SUM(o.rating * o.rating) - POW(SUM(o.rating), 2))
           ),
           0
       ) AS delivery_time_rating_correlation
FROM zomato_orders AS o
WHERE o.order_status <> 'Cancelled'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
  AND o.delivery_time IS NOT NULL
  AND o.rating IS NOT NULL;

-- Delivery-distance bands and average delivery time.
SELECT CASE
           WHEN o.delivery_distance >= 0 AND o.delivery_distance <= 3 THEN '0-3 km'
           WHEN o.delivery_distance > 3 AND o.delivery_distance <= 6 THEN '>3-6 km'
           WHEN o.delivery_distance > 6 AND o.delivery_distance <= 9 THEN '>6-9 km'
           WHEN o.delivery_distance > 9 AND o.delivery_distance <= 12 THEN '>9-12 km'
           WHEN o.delivery_distance > 12 AND o.delivery_distance <= 15 THEN '>12-15 km'
           WHEN o.delivery_distance > 15 THEN '>15 km'
           ELSE 'Outside defined bands'
       END AS delivery_distance_band,
       COUNT(DISTINCT o.order_id) AS order_count,
       ROUND(AVG(o.delivery_time), 2) AS average_delivery_time
FROM zomato_orders AS o
WHERE o.order_status <> 'Cancelled'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
  AND o.delivery_distance IS NOT NULL
  AND o.delivery_time IS NOT NULL
GROUP BY delivery_distance_band
ORDER BY MIN(o.delivery_distance);

-- Pearson correlation: delivery distance vs delivery time.
-- Correctly filters non-null distance and delivery time (the original file filtered rating instead).
SELECT (
           COUNT(*) * SUM(o.delivery_distance * o.delivery_time)
           - SUM(o.delivery_distance) * SUM(o.delivery_time)
       ) /
       NULLIF(
           SQRT(
               (COUNT(*) * SUM(o.delivery_distance * o.delivery_distance) - POW(SUM(o.delivery_distance), 2))
               *
               (COUNT(*) * SUM(o.delivery_time * o.delivery_time) - POW(SUM(o.delivery_time), 2))
           ),
           0
       ) AS distance_delivery_time_correlation
FROM zomato_orders AS o
WHERE o.order_status <> 'Cancelled'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
  AND o.delivery_distance IS NOT NULL
  AND o.delivery_time IS NOT NULL;

/* ============================================================================
   08. PROMOTIONS AND FREE DELIVERY
   ============================================================================ */

-- Distribution of non-cancelled orders by promo-code and free-delivery combination.
SELECT o.promo_code_applied,
       o.has_free_delivery,
       COUNT(DISTINCT o.order_id) AS order_count,
       SUM(o.order_amount) AS order_value,
       ROUND(AVG(o.order_amount), 2) AS aov
FROM zomato_orders AS o
WHERE o.order_status <> 'Cancelled'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
GROUP BY o.promo_code_applied, o.has_free_delivery
ORDER BY o.promo_code_applied, o.has_free_delivery;

-- Separate summary by free-delivery flag.
SELECT o.has_free_delivery,
       COUNT(DISTINCT o.order_id) AS order_count,
       SUM(o.order_amount) AS order_value,
       ROUND(AVG(o.order_amount), 2) AS aov
FROM zomato_orders AS o
WHERE o.order_status <> 'Cancelled'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
GROUP BY o.has_free_delivery;

-- Separate summary by promo-code flag.
SELECT o.promo_code_applied,
       COUNT(DISTINCT o.order_id) AS order_count,
       SUM(o.order_amount) AS order_value,
       ROUND(AVG(o.order_amount), 2) AS aov
FROM zomato_orders AS o
WHERE o.order_status <> 'Cancelled'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
GROUP BY o.promo_code_applied;

/* ============================================================================
   09. CANCELLATION ANALYSIS
   ============================================================================ */

-- Overall cancellation metrics in the valid analysis period.
SELECT COUNT(DISTINCT o.order_id) AS total_orders,
       COUNT(DISTINCT CASE WHEN o.order_status = 'Cancelled' THEN o.order_id END)
           AS cancelled_orders,
       ROUND(
           100.0 * COUNT(DISTINCT CASE WHEN o.order_status = 'Cancelled' THEN o.order_id END)
           / NULLIF(COUNT(DISTINCT o.order_id), 0),
           2
       ) AS cancellation_rate_pct,
       SUM(CASE WHEN o.order_status = 'Cancelled' THEN o.order_amount ELSE 0 END)
           AS cancelled_order_value
FROM zomato_orders AS o
WHERE STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30';

-- Cancellation rate by quarter.
SELECT YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) AS order_year,
       QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) AS order_quarter,
       COUNT(DISTINCT o.order_id) AS total_orders,
       COUNT(DISTINCT CASE WHEN o.order_status = 'Cancelled' THEN o.order_id END)
           AS cancelled_orders,
       ROUND(
           100.0 * COUNT(DISTINCT CASE WHEN o.order_status = 'Cancelled' THEN o.order_id END)
           / NULLIF(COUNT(DISTINCT o.order_id), 0),
           2
       ) AS cancellation_rate_pct
FROM zomato_orders AS o
WHERE STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
GROUP BY YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')),
         QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y'))
ORDER BY order_year, order_quarter;

-- City cancellation rates and cancelled order value; retain cities with at least 50 orders.
SELECT r.city,
       COUNT(DISTINCT o.order_id) AS total_orders,
       COUNT(DISTINCT CASE WHEN o.order_status = 'Cancelled' THEN o.order_id END) AS cancelled_orders,
       ROUND(
           100.0 * COUNT(DISTINCT CASE WHEN o.order_status = 'Cancelled' THEN o.order_id END)
           / NULLIF(COUNT(DISTINCT o.order_id), 0),
           2
       ) AS cancellation_rate_pct,
       SUM(CASE WHEN o.order_status = 'Cancelled' THEN o.order_amount ELSE 0 END)
           AS cancelled_order_value
FROM zomato_restaurants AS r
JOIN zomato_orders AS o
    ON r.res_id = o.res_id
WHERE STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
GROUP BY r.city
HAVING COUNT(DISTINCT o.order_id) >= 50
ORDER BY cancelled_order_value DESC;

-- Compare cancellation rate with average distance/time and promotion/free-delivery rates.
-- Metrics are descriptive; they do not establish what causes cancellation.
SELECT r.city,
       COUNT(DISTINCT o.order_id) AS total_orders,
       ROUND(AVG(o.delivery_distance), 2) AS average_delivery_distance,
       ROUND(AVG(o.delivery_time), 2) AS average_delivery_time,
       ROUND(100.0 * SUM(o.promo_code_applied = 'Yes') / COUNT(DISTINCT o.order_id), 2)
           AS promo_usage_rate_pct,
       ROUND(100.0 * SUM(o.has_free_delivery = 'Yes') / COUNT(DISTINCT o.order_id), 2)
           AS free_delivery_rate_pct,
       ROUND(100.0 * SUM(o.order_status = 'Cancelled') / COUNT(DISTINCT o.order_id), 2)
           AS cancellation_rate_pct
FROM zomato_restaurants AS r
JOIN zomato_orders AS o
    ON r.res_id = o.res_id
WHERE STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
  AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
GROUP BY r.city
HAVING COUNT(DISTINCT o.order_id) >= 50
ORDER BY cancellation_rate_pct DESC
LIMIT 5;

/* ============================================================================
   10. GRANULAR CITY GROWTH: JANUARY–SEPTEMBER 2023 VS 2024
   ============================================================================ */

-- City-level order volume, order value, and AOV growth across comparable nine-month periods.
-- Minimum combined volume: 50 non-cancelled orders across both periods.
-- NULLIF prevents division-by-zero when a city has no baseline orders/value.
WITH city_growth AS (
    SELECT r.city,
           SUM(CASE
                   WHEN YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2023
                    AND QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) IN (1, 2, 3)
                   THEN 1 ELSE 0
               END) AS orders_2023,
           SUM(CASE
                   WHEN YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2024
                    AND QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) IN (1, 2, 3)
                   THEN 1 ELSE 0
               END) AS orders_2024,
           SUM(CASE
                   WHEN YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2023
                    AND QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) IN (1, 2, 3)
                   THEN o.order_amount ELSE 0
               END) AS value_2023,
           SUM(CASE
                   WHEN YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2024
                    AND QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) IN (1, 2, 3)
                   THEN o.order_amount ELSE 0
               END) AS value_2024
    FROM zomato_restaurants AS r
    JOIN zomato_orders AS o
        ON r.res_id = o.res_id
    WHERE o.order_status <> 'Cancelled'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
    GROUP BY r.city
)
SELECT city,
       orders_2023,
       orders_2024,
       ROUND(100.0 * (orders_2024 - orders_2023) / NULLIF(orders_2023, 0), 2)
           AS order_growth_pct,
       value_2023,
       value_2024,
       ROUND(100.0 * (value_2024 - value_2023) / NULLIF(value_2023, 0), 2)
           AS order_value_growth_pct,
       ROUND(value_2023 / NULLIF(orders_2023, 0), 2) AS aov_2023,
       ROUND(value_2024 / NULLIF(orders_2024, 0), 2) AS aov_2024,
       ROUND(
           100.0 * (
               (value_2024 / NULLIF(orders_2024, 0))
               - (value_2023 / NULLIF(orders_2023, 0))
           ) / NULLIF(value_2023 / NULLIF(orders_2023, 0), 0),
           2
       ) AS aov_growth_pct
FROM city_growth
WHERE orders_2023 + orders_2024 >= 50
ORDER BY order_growth_pct DESC, city;

-- Quarter-by-quarter order-volume growth for Q1-Q3 2023 vs Q1-Q3 2024.
-- The positive_quarters metric counts quarters where 2024 volume is greater than 2023.
WITH city_growth_quarterly AS (
    SELECT r.city,
           SUM(CASE WHEN YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2023
                          AND QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 1 THEN 1 ELSE 0 END) AS q1_2023,
           SUM(CASE WHEN YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2024
                          AND QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 1 THEN 1 ELSE 0 END) AS q1_2024,
           SUM(CASE WHEN YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2023
                          AND QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2 THEN 1 ELSE 0 END) AS q2_2023,
           SUM(CASE WHEN YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2024
                          AND QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2 THEN 1 ELSE 0 END) AS q2_2024,
           SUM(CASE WHEN YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2023
                          AND QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 3 THEN 1 ELSE 0 END) AS q3_2023,
           SUM(CASE WHEN YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2024
                          AND QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 3 THEN 1 ELSE 0 END) AS q3_2024
    FROM zomato_restaurants AS r
    JOIN zomato_orders AS o
        ON r.res_id = o.res_id
    WHERE o.order_status <> 'Cancelled'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
    GROUP BY r.city
)
SELECT city,
       q1_2023, q1_2024,
       ROUND(100.0 * (q1_2024 - q1_2023) / NULLIF(q1_2023, 0), 2) AS q1_order_growth_pct,
       q2_2023, q2_2024,
       ROUND(100.0 * (q2_2024 - q2_2023) / NULLIF(q2_2023, 0), 2) AS q2_order_growth_pct,
       q3_2023, q3_2024,
       ROUND(100.0 * (q3_2024 - q3_2023) / NULLIF(q3_2023, 0), 2) AS q3_order_growth_pct,
       (q1_2024 > q1_2023) + (q2_2024 > q2_2023) + (q3_2024 > q3_2023)
           AS positive_growth_quarters
FROM city_growth_quarterly
WHERE q1_2023 + q1_2024 + q2_2023 + q2_2024 + q3_2023 + q3_2024 >= 50
ORDER BY positive_growth_quarters DESC, city;

-- Quarter-by-quarter order-value growth. Uses the same combined 50-order screen as above.
WITH city_growth_quarterly AS (
    SELECT r.city,
           SUM(CASE WHEN YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2023
                          AND QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 1 THEN o.order_amount ELSE 0 END) AS q1_value_2023,
           SUM(CASE WHEN YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2024
                          AND QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 1 THEN o.order_amount ELSE 0 END) AS q1_value_2024,
           SUM(CASE WHEN YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2023
                          AND QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2 THEN o.order_amount ELSE 0 END) AS q2_value_2023,
           SUM(CASE WHEN YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2024
                          AND QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2 THEN o.order_amount ELSE 0 END) AS q2_value_2024,
           SUM(CASE WHEN YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2023
                          AND QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 3 THEN o.order_amount ELSE 0 END) AS q3_value_2023,
           SUM(CASE WHEN YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 2024
                          AND QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) = 3 THEN o.order_amount ELSE 0 END) AS q3_value_2024,
           SUM(CASE
                   WHEN YEAR(STR_TO_DATE(o.order_date, '%d-%m-%Y')) IN (2023, 2024)
                    AND QUARTER(STR_TO_DATE(o.order_date, '%d-%m-%Y')) IN (1, 2, 3)
                   THEN 1 ELSE 0
               END) AS comparable_period_orders
    FROM zomato_restaurants AS r
    JOIN zomato_orders AS o
        ON r.res_id = o.res_id
    WHERE o.order_status <> 'Cancelled'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') >= '2023-01-01'
      AND STR_TO_DATE(o.order_date, '%d-%m-%Y') <= '2024-09-30'
    GROUP BY r.city
)
SELECT city,
       q1_value_2023, q1_value_2024,
       ROUND(100.0 * (q1_value_2024 - q1_value_2023) / NULLIF(q1_value_2023, 0), 2)
           AS q1_order_value_growth_pct,
       q2_value_2023, q2_value_2024,
       ROUND(100.0 * (q2_value_2024 - q2_value_2023) / NULLIF(q2_value_2023, 0), 2)
           AS q2_order_value_growth_pct,
       q3_value_2023, q3_value_2024,
       ROUND(100.0 * (q3_value_2024 - q3_value_2023) / NULLIF(q3_value_2023, 0), 2)
           AS q3_order_value_growth_pct
FROM city_growth_quarterly
WHERE comparable_period_orders >= 50
ORDER BY q3_order_value_growth_pct DESC, city;
