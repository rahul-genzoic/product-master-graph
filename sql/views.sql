-- Helper views for the product-master context graph.
-- Run ONCE in BigQuery (project erp-set-up) before `contextgraph apply`.
--   bq query --use_legacy_sql=false < sql/views.sql
-- or paste into the BigQuery console.
--
-- PIM views live in ctx_upside_master_data. Live views live in bronze and
-- reach silver/gold via fully-qualified names.

-- =====================================================================
-- PIM (gen-lang-client-0520145261.ctx_upside_master_data)
-- =====================================================================

-- Product node: flatten the three 1:1 facets onto DIM_PRODUCT so Product
-- is one clean node (mirrors how Monginis folded pricing onto Product).
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_ENRICHED` AS
SELECT
  p.SKU,
  p.DISPLAY_NAME,
  p.FLAVOUR,
  p.SIZE_GM,
  p.SIZE_LABEL,
  p.VERSION,
  p.STATUS,
  p.VEG_NONVEG,
  p.IS_ACTIVE,
  p.DESCRIPTION,
  p.IMAGES_LINK,
  pr.BASE_PRICE_INR,
  pr.GST_RATE,
  pr.MRP_INR,
  pr.TOTAL_COGS_INR,
  pr.SHELF_LIFE_DAYS,
  pk.PACKAGING_TYPE,
  pk.GS1_BARCODE,
  pk.ORG_LABELLING_COMPLIANCE,
  nu.SERVING_SIZE
FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT` p
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_PRICING`   pr USING (SKU)
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_PACKAGING` pk USING (SKU)
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_NUTRITION` nu USING (SKU);

-- Claim node: give each highlight a stable single-column id.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_CLAIM` AS
SELECT
  CONCAT(SKU, '-', CAST(HIGHLIGHT_SEQ AS STRING)) AS CLAIM_ID,
  SKU,
  HIGHLIGHT_SEQ,
  HIGHLIGHT_TEXT
FROM `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_HIGHLIGHT`;

-- Nutrient dimension (empty until parse_nutrients.py populates PRODUCT_NUTRIENT).
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_NUTRIENT_DIM` AS
SELECT DISTINCT NUTRIENT_NAME
FROM `gen-lang-client-0520145261.ctx_upside_master_data.PRODUCT_NUTRIENT`;

-- Manufacturing capability envelope: one row per product line actually made
-- today, with category, active SKU count, observed COGS range and shelf life.
-- Feeds idea_capture_triage's feasibility step — a form factor absent from this
-- view is one the company has NEVER produced.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_LINE_CAPABILITY` AS
SELECT
  l.PRODUCT_LINE_ID,
  l.PRODUCT_LINE_NAME,
  c.CATEGORY_NAME,
  COUNT(*)                      AS ACTIVE_SKUS,
  ROUND(MIN(v.TOTAL_COGS_INR))  AS MIN_COGS_INR,
  ROUND(MAX(v.TOTAL_COGS_INR))  AS MAX_COGS_INR,
  ROUND(AVG(v.SHELF_LIFE_DAYS)) AS AVG_SHELF_LIFE_DAYS
FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT` d
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.V_PRODUCT_ENRICHED` v ON v.SKU = d.SKU
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT_LINE`   l ON l.PRODUCT_LINE_ID = d.PRODUCT_LINE_ID
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_CATEGORY`       c ON c.CATEGORY_ID = d.CATEGORY_ID
WHERE v.IS_ACTIVE
GROUP BY 1, 2, 3;

-- Triage similarity candidates: every pipeline idea plus every active competitor
-- product, unioned into ONE rowset so idea_capture_triage's first step can pull
-- them through a single step-level `fetch:` and see them UN-TRUNCATED. Reading
-- them as two separate context_package keys previews each list down to 4 rows
-- (_compact_facts), which silently hid 12 of 16 competitor products.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.ctx_upside_master_data.V_TRIAGE_SIMILARITY_CANDIDATES` AS
SELECT
  'IDEA'                                AS SOURCE,
  i.IDEA_ID                             AS CANDIDATE_ID,
  i.NAME                                AS NAME,
  i.STAGE                               AS STAGE,
  i.HYPOTHESIS                          AS HYPOTHESIS,
  i.THESIS_FIT                          AS THESIS_FIT,
  CAST(i.TARGET_COGS_INR AS STRING)     AS TARGET_COGS_INR,
  CAST(NULL AS STRING)                  AS CITY,
  CAST(NULL AS STRING)                  AS COMPETITOR_ID,
  CAST(NULL AS STRING)                  AS CATEGORY
FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_IDEA` i
UNION ALL
SELECT
  'COMPETITOR_PRODUCT'                  AS SOURCE,
  cp.COMPETITOR_PRODUCT_ID              AS CANDIDATE_ID,
  cp.PRODUCT_NAME                       AS NAME,
  CAST(NULL AS STRING)                  AS STAGE,
  CAST(NULL AS STRING)                  AS HYPOTHESIS,
  CAST(NULL AS STRING)                  AS THESIS_FIT,
  CAST(NULL AS STRING)                  AS TARGET_COGS_INR,
  cp.CITY                               AS CITY,
  cp.COMPETITOR_ID                      AS COMPETITOR_ID,
  cm.CATEGORY                           AS CATEGORY
FROM `gen-lang-client-0520145261.ctx_upside_master_data.DIM_COMPETITOR_PRODUCT` cp
LEFT JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_COMPETITOR` cm
  ON cm.COMPETITOR_ID = cp.COMPETITOR_ID AND cm.IS_ACTIVE
WHERE cp.IS_ACTIVE;

-- =====================================================================
-- LIVE (gen-lang-client-0520145261.bronze / silver / gold)
-- =====================================================================

-- Complaint node: EVENT_ID is null for rows ingested via the email-parsing
-- path (no ticketing EVENT_ID was ever assigned) — EMAIL_MESSAGE_ID is
-- present and unique whenever EVENT_ID isn't, so coalesce them into one
-- always-populated, always-unique id.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_COMPLAINT_EVENTS` AS
SELECT * REPLACE (COALESCE(EVENT_ID, EMAIL_MESSAGE_ID) AS EVENT_ID)
FROM `gen-lang-client-0520145261.bronze.CUSTOMER_COMPLAINT_EVENTS`;

-- stocked_at edge: latest FLAGGED_INVENTORY row per store x SKU (one edge each).
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_STOCKED_AT` AS
SELECT * EXCEPT(rn) FROM (
  SELECT
    SKU_ID,
    MASTER_STORE_ID,
    TOTAL_STOCK,
    SAFE_STOCK,
    EXPIRED_STOCK,
    SOONEST_EXPIRY,
    QTY_EXPIRING_WITHIN_RISK_DAYS,
    WASTAGE_FLAG,
    LOW_STOCK_FLAG,
    SHELF_LIFE_DAYS,
    ROW_NUMBER() OVER (PARTITION BY MASTER_STORE_ID, SKU_ID ORDER BY REPORT_DATE DESC) AS rn
  FROM `gen-lang-client-0520145261.bronze.FLAGGED_INVENTORY`
)
WHERE rn = 1;

-- (forecast: no view. The Product "Forecast quantity by store" widget queries
-- the gold base table gold.FORECAST_RESULTS_UPDATE directly via a raw widget
-- query — latest run, next 1-3 days, summed per store. See link_datasets.yaml.)

-- transfer_route edge: FROM/TO_STORE_ID are the same store identity as
-- MASTER_STORE_ID (confirmed) — cast INT64 -> STRING to bridge the type difference.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_TRANSFER_ROUTE` AS
SELECT
  CAST(FROM_STORE_ID AS STRING) AS FROM_STORE_ID,
  CAST(TO_STORE_ID   AS STRING) AS TO_STORE_ID,
  DISTANCE_KM,
  PREFERRED_FOR_TRANSFER
FROM `gen-lang-client-0520145261.bronze.STORE_TRANSFER_DISTANCES`;

-- complaint_about_product edge (OPTIONAL, deferred): fuzzy item-name -> SKU.
-- Enable the edge in live_bq.yaml once you've validated the match rate.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_COMPLAINT_RESOLVED` AS
SELECT
  c.EVENT_ID,
  p.SKU AS SKU_ID
FROM `gen-lang-client-0520145261.bronze.V_COMPLAINT_EVENTS` c
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_PRODUCT` p
  ON UPPER(TRIM(c.ITEM_NAME)) = UPPER(TRIM(p.DISPLAY_NAME));

-- =====================================================================
-- MARKETING (gen-lang-client-0520145261.bronze)  —  campaigns + segments
-- =====================================================================

-- Store's currently-running campaigns this month. RAW_MARKETING_DATA is ad
-- data at the daily x campaign grain with no store id — RES_ID is a
-- platform-specific ad/restaurant id (Zomato/Urban Piper/Petpooja/Swiggy),
-- resolved to MASTER_STORE_ID via STORE_CHANNEL_MAPPING, matching RES_ID
-- against whichever of ZOMATO_ID/URBAN_PIPER_ID/PETPOOJA_ID/SWIGGY_ID it came
-- from (INT64 -> STRING). Keeps only campaigns live today (CURRENT_DATE
-- between START/END) and sums this calendar month's daily rows to one row
-- per campaign. Dynamic on CURRENT_DATE(), so it re-scopes to "this month /
-- running now" on every render — this is a fast-moving lazy link, not
-- materialised on apply.
-- matched_platform/RES_ID kept for traceability (which platform id resolved this row);
-- ROI/ADS_M2O_PCT/OVERALL_M2O_PCT recomputed from the summed totals (SAFE_DIVIDE) rather
-- than averaging RAW_MARKETING_DATA's daily per-row ratios, since this view is already
-- collapsing daily rows to one this-month-to-date row per store x campaign. DATE here is
-- MAX(r.DATE) — the most recent daily row rolled into this total, not a per-day value.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_STORE_CAMPAIGN_CURRENT` AS
SELECT
  m.MASTER_STORE_ID,
  r.CAMPAIGN_ID,
  ANY_VALUE(r.RES_ID) AS RES_ID,
  ANY_VALUE(
    CASE
      WHEN r.RES_ID = CAST(m.ZOMATO_ID AS STRING) THEN 'ZOMATO'
      WHEN r.RES_ID = CAST(m.SWIGGY_ID AS STRING) THEN 'SWIGGY'
      ELSE 'UNKNOWN'
    END
  ) AS PLATFORM,
  ANY_VALUE(r.PRODUCT_TYPE) AS PRODUCT_TYPE,
  ANY_VALUE(r.TARGETING) AS TARGETING,
  ANY_VALUE(r.SEGMENTS) AS SEGMENTS,
  MAX(r.DATE) AS DATE,
  MIN(r.START_DATE) AS START_DATE,
  MAX(r.END_DATE) AS END_DATE,
  ROUND(SUM(r.AD_SPEND_RS), 0) AS AD_SPEND_RS,
  ROUND(SUM(r.AD_SALES_RS), 0) AS AD_SALES_RS,
  SUM(r.AD_ORDERS) AS AD_ORDERS,
  SUM(r.AD_IMPRESSIONS) AS AD_IMPRESSIONS,
  SUM(r.AD_CLICKS) AS AD_CLICKS,
  SAFE_DIVIDE(SUM(r.AD_SALES_RS), SUM(r.AD_SPEND_RS)) AS ROI,
  ANY_VALUE(CAST(r.ADS_M2O_PCT AS FLOAT64)) AS ADS_M2O_PCT,
  ANY_VALUE(CAST(r.OVERALL_M2O_PCT AS FLOAT64)) AS OVERALL_M2O_PCT,
  -- ROAS/CTR computed here (not by the campaign_planning_optimisation agent step)
  -- because the process YAML's compute DSL has no arithmetic op (see days_until/
  -- bucket only) — same reason ROI/ADS_M2O_PCT/OVERALL_M2O_PCT above are SAFE_DIVIDE
  -- here rather than in the process. Keeping the agent step's job to "read this
  -- number" instead of "compute this number" removes a place it was reaching for a
  -- tool call instead.
  SAFE_DIVIDE(SUM(r.AD_SALES_RS), SUM(r.AD_SPEND_RS)) AS ROAS,
  SAFE_DIVIDE(SUM(r.AD_CLICKS), SUM(r.AD_IMPRESSIONS)) AS CTR
FROM `gen-lang-client-0520145261.bronze.RAW_MARKETING_DATA` r
JOIN `gen-lang-client-0520145261.bronze.STORE_CHANNEL_MAPPING` m
  ON r.RES_ID IN (
      CAST(m.ZOMATO_ID AS STRING),
      CAST(m.SWIGGY_ID AS STRING)
  )
WHERE r.DATE >= DATE_TRUNC(CURRENT_DATE(), MONTH)
  AND CURRENT_DATE() BETWEEN r.START_DATE AND r.END_DATE
GROUP BY
  m.MASTER_STORE_ID,
  r.CAMPAIGN_ID;

-- segment_on_channel edge: MARKETING_SEGMENT_MASTER.CHANNEL ('SWIGGY'/'ZOMATO')
-- resolves to the Channel node by name (DIM_CHANNEL.CHANNEL_NAME). Gives each
-- CustomerSegment its Channel id (CH-012 Swiggy / CH-015 Zomato).
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_SEGMENT_ON_CHANNEL` AS
SELECT
  s.SEGMENT_ID,
  ch.CHANNEL_ID
FROM `gen-lang-client-0520145261.bronze.MARKETING_SEGMENT_MASTER` s
JOIN `gen-lang-client-0520145261.ctx_upside_master_data.DIM_CHANNEL` ch
  ON UPPER(ch.CHANNEL_NAME) = UPPER(s.CHANNEL);

-- Segment budget allocations: MARKETING_BUDGET.SEGMENT_TYPE == SEGMENT_CODE
-- (per channel) -> exposes SEGMENT_ID so the link can scope to one segment.
-- Shows which stores fund this segment, on which channel, and how much.
CREATE OR REPLACE VIEW `gen-lang-client-0520145261.bronze.V_SEGMENT_BUDGET` AS
SELECT
  s.SEGMENT_ID,
  b.MASTER_STORE_ID,
  b.STORE_NAME,
  b.CHANNEL,
  b.BUDGET_MONTH,
  b.ALLOCATED_BUDGET_RS,
  b.EXPECTED_REVENUE_RS
FROM `gen-lang-client-0520145261.bronze.MARKETING_BUDGET` b
JOIN `gen-lang-client-0520145261.bronze.MARKETING_SEGMENT_MASTER` s
  ON b.SEGMENT_TYPE = s.SEGMENT_CODE
 AND UPPER(b.CHANNEL) = UPPER(s.CHANNEL);