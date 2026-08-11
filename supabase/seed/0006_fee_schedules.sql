-- T08 — fee_schedules.
--
-- Source of truth for the amazon_uk rows: Amazon's own "Rate Card — Europe
-- Fees, Effective as of 1st July 2026" (the UK / £ column), read on 2026-08-11:
--   https://m.media-amazon.com/images/G/02/sell/images/260630-FBA-Rate-Card-EN1.pdf
-- The UK fulfilment, storage and referral tables in that card are byte-identical
-- to the preceding 1 February 2026 card; the only UK change between them is the
-- fuel and logistics surcharge, which is why there are two amazon_uk versions
-- below rather than one.
--
-- ===========================================================================
-- WHY TWO amazon_uk VERSIONS
-- ===========================================================================
--
--   [2026-02-01, 2026-04-17)  rate card fees, no fuel surcharge
--   [2026-04-17, ∞)           same fees, plus the 1.5% fuel and logistics
--                             surcharge that began on 2026-04-17
--
-- Adjacent, half-open, exactly as ADR-0012 requires, and only the current row
-- is open-ended. The shared tables are defined once in the CTE below and both
-- rows select from it, so the two versions cannot drift apart by a typo — the
-- only thing that differs between them is the `surcharges` list, which is the
-- only thing that actually differs.
--
-- ===========================================================================
-- THE SURCHARGE `basis` VOCABULARY IS EXTENDED HERE — DELIBERATELY, AND THIS
-- IS THE ONE DEVIATION IN THIS SEED
-- ===========================================================================
--
-- ARCHITECTURE.md §2.2 defines a surcharge entry as
--   {code, label, basis: 'referral_fee'|'sell_price'|'flat', rate_bps|amount_minor, applies_to_countries?}
--
-- Two of the three real UK surcharges cannot be expressed in that vocabulary:
--
--   * The Digital Services Fee applies to Selling on Amazon fees AND FBA fees.
--     `basis: 'referral_fee'` would capture only the first half.
--   * The fuel and logistics surcharge applies to fulfilment fees alone. There
--     is no basis for that at all.
--
-- Forcing both onto 'referral_fee' would UNDERSTATE cost — the direction that
-- overstates profit, which is risk #5. So `basis` gains two values here,
-- 'selling_fees' (referral + fulfilment) and 'fulfilment_fee', and a third key,
-- `applies_to_categories`, which the media closing fee needs and which §2.2's
-- `applies_to_countries?` has no analogue for.
--
-- This is a real deviation from §2.2 and is written down rather than absorbed:
-- the pricing engine (T14) and its surcharge module must implement all four
-- bases, and §2.2's list needs amending. Nothing consumes `surcharges` yet, so
-- the extension costs nothing today and would cost a data migration later.
--
-- ===========================================================================
-- SHAPES USED BELOW (none is imposed by the schema; all are conventions this
-- seed establishes and the seed tests assert)
-- ===========================================================================
--
-- referral_rules: ordered list, LAST entry is the catch-all with
--   "default": true, which is what makes category coverage total by
--   construction rather than by hoping the category list is complete.
--     {code, label, mode, tiers[], min_fee_minor, default?}
--   mode:
--     "flat"      one tier, rate applies to the whole price.
--     "threshold" the tier is SELECTED by the whole price, then its rate
--                 applies to the whole price. Amazon writes these as
--                 "8% for products with a total price up to £10".
--     "marginal"  each tier's rate applies only to the PORTION of the price
--                 within it. Amazon writes these as "15% for the portion of
--                 the total price up to £45".
--   The mode distinction is not cosmetic: on a £60 Automotive item, marginal
--   gives £45x15% + £15x9% = £8.10 and threshold would give £60x9% = £5.40.
--   Getting it backwards is a ~30% error on the fee.
--   tiers: ordered, {up_to_minor, rate_bps}. `up_to_minor` is an INCLUSIVE
--   upper bound, matching Amazon's own "up to £10.00 / greater than £10.00"
--   wording; null means unbounded and may appear only in the final tier.
--
-- fulfilment_bands: ordered list, one entry per (size tier, weight band).
--     {tier, tier_label, sort_order, max_dims_mm{}, max_unit_weight_g,
--      max_dimensional_weight_g, from_weight_g, to_weight_g, amount_minor,
--      per_kg_over_minor?}
--   WEIGHT BANDS ARE (from, to] — EXCLUSIVE LOWER, INCLUSIVE UPPER. This is
--   the opposite of the [from, to) used for schedule PERIODS, and the
--   difference is intentional: Amazon states every band as "≤ 20 g", weight is
--   continuous rather than discrete, and re-basing the printed bounds to
--   half-open would move every boundary item into the neighbouring band.
--   Within one tier the bands are contiguous — band[i].from_weight_g equals
--   band[i-1].to_weight_g — which is what the "no gaps or overlaps" test
--   checks.
--   Amazon prints each tier's bands with the lower bound left implicit (a
--   ≤210 g item at envelope dimensions is a Standard envelope only if it is
--   also over 100 g, or it would be a Light envelope). The seed makes that
--   implied lower bound explicit, because a bound that exists only in a
--   reader's head cannot be tested.
--   `per_kg_over_minor` is the "+£0.25/kg" form: the band's amount_minor is the
--   base and the per-kg rate applies to weight above from_weight_g.
--
-- storage_rules: {unit, currency, periods[], rates[], notes}. UK storage is
--   billed per CUBIC FOOT and the rest of Europe per cubic metre — `unit` is
--   therefore data, and a pricing engine that assumed m³ would be out by a
--   factor of ~35.

with uk as (
  select
    -- ---------------------------------------------------------------------
    -- UK referral fees — rate card p.28-30, UK/£ column. Complete category
    -- list as printed; "everything_else" is Amazon's own catch-all row.
    -- Minimum referral fee is £0.25 for all categories (footnote 3).
    -- ---------------------------------------------------------------------
    '[
      {"code": "amazon_device_accessories", "label": "Amazon Device Accessories", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 4500}]},
      {"code": "automotive_and_powersports", "label": "Automotive and Powersports", "mode": "marginal", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": 4500, "rate_bps": 1500}, {"up_to_minor": null, "rate_bps": 900}]},
      {"code": "baby_products", "label": "Baby Products", "mode": "threshold", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": 1000, "rate_bps": 800}, {"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "baby_pushchairs_and_safety_equipment", "label": "Baby Pushchairs and Safety Equipment", "mode": "threshold", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": 1000, "rate_bps": 800}, {"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "rucksacks_and_handbags", "label": "Rucksacks and Handbags", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "beauty_health_and_personal_care", "label": "Beauty, Health and Personal Care; Personal care appliances", "mode": "threshold", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": 1000, "rate_bps": 800}, {"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "reusable_work_and_safety_gloves", "label": "Reusable Work and Safety Gloves", "mode": "threshold", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": 1000, "rate_bps": 800}, {"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "beer_wine_and_spirits", "label": "Beer, Wine and Spirits", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1000}]},
      {"code": "books", "label": "Books", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "business_industrial_and_scientific_supplies", "label": "Business, Industrial and Scientific Supplies", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "compact_appliances", "label": "Compact Appliances", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "clothing_and_accessories", "label": "Clothing and Accessories", "mode": "threshold", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": 1500, "rate_bps": 500}, {"up_to_minor": 2000, "rate_bps": 1000}, {"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "commercial_electrical_and_energy_supplies", "label": "Commercial Electrical and Energy Supplies", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1200}]},
      {"code": "computers", "label": "Computers", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 700}]},
      {"code": "consumer_electronics", "label": "Consumer Electronics", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 700}]},
      {"code": "cycling_accessories", "label": "Cycling Accessories", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "electronic_accessories_and_computer_accessories", "label": "Electronic Accessories; Computer accessories", "mode": "marginal", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": 10000, "rate_bps": 1500}, {"up_to_minor": null, "rate_bps": 800}]},
      {"code": "printer_and_scanner_accessories", "label": "Printer and Scanner Accessories", "mode": "marginal", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": 10000, "rate_bps": 1500}, {"up_to_minor": null, "rate_bps": 800}]},
      {"code": "eyewear", "label": "Eyewear", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "eyewear_protection", "label": "Eyewear Protection", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "footwear", "label": "Footwear", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "full_size_appliances", "label": "Full-Size Appliances", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 700}]},
      {"code": "furniture", "label": "Furniture", "mode": "marginal", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": 17500, "rate_bps": 1500}, {"up_to_minor": null, "rate_bps": 1000}]},
      {"code": "furniture_accessories", "label": "Furniture Accessories", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1300}]},
      {"code": "grocery_and_gourmet", "label": "Grocery and Gourmet", "mode": "threshold", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": 1000, "rate_bps": 500}, {"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "handmade", "label": "Handmade", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1200}]},
      {"code": "home_products", "label": "Home Products", "mode": "threshold", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": 2000, "rate_bps": 800}, {"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "kitchen", "label": "Kitchen", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "home_linen_and_rugs", "label": "Home Linen and Rugs", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "jewellery", "label": "Jewellery", "mode": "marginal", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": 22500, "rate_bps": 2000}, {"up_to_minor": null, "rate_bps": 500}]},
      {"code": "lawn_and_garden", "label": "Lawn and Garden", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "luggage", "label": "Luggage", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "luggage_accessories", "label": "Luggage Accessories", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "mattresses", "label": "Mattresses", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "music_video_and_dvd", "label": "Music, Video and DVD", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "musical_instruments_and_av_production", "label": "Musical Instruments and AV Production", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1200}]},
      {"code": "office_products", "label": "Office Products", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "packing_materials", "label": "Packing Materials", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "pet_supplies", "label": "Pet Supplies", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "pet_clothing_and_food", "label": "Pet Clothing and Food", "mode": "threshold", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": 1000, "rate_bps": 500}, {"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "software", "label": "Software", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "sports_and_outdoors", "label": "Sports and Outdoors", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "tyres", "label": "Tyres", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 700}]},
      {"code": "tools_and_home_improvement", "label": "Tools and Home Improvement", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1300}]},
      {"code": "door_window_and_shower_accessories", "label": "Door, Window and Shower Accessories", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1300}]},
      {"code": "home_adhesives_and_cable_ties", "label": "Home Adhesives and Cable Ties", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1300}]},
      {"code": "toys_and_games", "label": "Toys and Games", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "video_games_and_gaming_accessories", "label": "Video Games and Gaming Accessories", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "video_game_consoles", "label": "Video Game Consoles", "mode": "flat", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": null, "rate_bps": 800}]},
      {"code": "vitamins_minerals_and_supplements", "label": "Vitamins, Minerals & Supplements", "mode": "threshold", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": 1000, "rate_bps": 500}, {"up_to_minor": null, "rate_bps": 1500}]},
      {"code": "watches", "label": "Watches", "mode": "marginal", "min_fee_minor": 25,
       "tiers": [{"up_to_minor": 22500, "rate_bps": 1500}, {"up_to_minor": null, "rate_bps": 500}]},
      {"code": "everything_else", "label": "Everything else", "mode": "flat", "min_fee_minor": 25, "default": true,
       "tiers": [{"up_to_minor": null, "rate_bps": 1500}]}
    ]'::jsonb as referral_rules,

    -- ---------------------------------------------------------------------
    -- UK fulfilment fees — rate card p.6, "Local and Pan-European FBA", UK (£).
    -- Standard FBA only. Low-Price FBA (p.5) is a separate programme with its
    -- own rates and eligibility and is NOT seeded; a schedule that silently
    -- mixed the two would misprice every item near the £20 threshold.
    -- ---------------------------------------------------------------------
    '[
      {"tier": "light_envelope", "tier_label": "Light envelope", "sort_order": 1,
       "max_dims_mm": {"length": 330, "width": 230, "height": 25}, "max_unit_weight_g": 100, "max_dimensional_weight_g": null,
       "from_weight_g": 0, "to_weight_g": 20, "amount_minor": 183},
      {"tier": "light_envelope", "tier_label": "Light envelope", "sort_order": 1,
       "max_dims_mm": {"length": 330, "width": 230, "height": 25}, "max_unit_weight_g": 100, "max_dimensional_weight_g": null,
       "from_weight_g": 20, "to_weight_g": 40, "amount_minor": 187},
      {"tier": "light_envelope", "tier_label": "Light envelope", "sort_order": 1,
       "max_dims_mm": {"length": 330, "width": 230, "height": 25}, "max_unit_weight_g": 100, "max_dimensional_weight_g": null,
       "from_weight_g": 40, "to_weight_g": 60, "amount_minor": 189},
      {"tier": "light_envelope", "tier_label": "Light envelope", "sort_order": 1,
       "max_dims_mm": {"length": 330, "width": 230, "height": 25}, "max_unit_weight_g": 100, "max_dimensional_weight_g": null,
       "from_weight_g": 60, "to_weight_g": 80, "amount_minor": 207},
      {"tier": "light_envelope", "tier_label": "Light envelope", "sort_order": 1,
       "max_dims_mm": {"length": 330, "width": 230, "height": 25}, "max_unit_weight_g": 100, "max_dimensional_weight_g": null,
       "from_weight_g": 80, "to_weight_g": 100, "amount_minor": 208},

      {"tier": "standard_envelope", "tier_label": "Standard envelope", "sort_order": 2,
       "max_dims_mm": {"length": 330, "width": 230, "height": 25}, "max_unit_weight_g": 460, "max_dimensional_weight_g": null,
       "from_weight_g": 100, "to_weight_g": 210, "amount_minor": 210},
      {"tier": "standard_envelope", "tier_label": "Standard envelope", "sort_order": 2,
       "max_dims_mm": {"length": 330, "width": 230, "height": 25}, "max_unit_weight_g": 460, "max_dimensional_weight_g": null,
       "from_weight_g": 210, "to_weight_g": 460, "amount_minor": 216},

      {"tier": "large_envelope", "tier_label": "Large envelope", "sort_order": 3,
       "max_dims_mm": {"length": 330, "width": 230, "height": 40}, "max_unit_weight_g": 960, "max_dimensional_weight_g": null,
       "from_weight_g": 0, "to_weight_g": 960, "amount_minor": 272},

      {"tier": "extra_large_envelope", "tier_label": "Extra-large envelope", "sort_order": 4,
       "max_dims_mm": {"length": 330, "width": 230, "height": 60}, "max_unit_weight_g": 960, "max_dimensional_weight_g": null,
       "from_weight_g": 0, "to_weight_g": 960, "amount_minor": 294},

      {"tier": "small_parcel", "tier_label": "Small parcel", "sort_order": 5,
       "max_dims_mm": {"length": 350, "width": 250, "height": 120}, "max_unit_weight_g": 3900, "max_dimensional_weight_g": 2100,
       "from_weight_g": 0, "to_weight_g": 150, "amount_minor": 291},
      {"tier": "small_parcel", "tier_label": "Small parcel", "sort_order": 5,
       "max_dims_mm": {"length": 350, "width": 250, "height": 120}, "max_unit_weight_g": 3900, "max_dimensional_weight_g": 2100,
       "from_weight_g": 150, "to_weight_g": 400, "amount_minor": 300},
      {"tier": "small_parcel", "tier_label": "Small parcel", "sort_order": 5,
       "max_dims_mm": {"length": 350, "width": 250, "height": 120}, "max_unit_weight_g": 3900, "max_dimensional_weight_g": 2100,
       "from_weight_g": 400, "to_weight_g": 900, "amount_minor": 304},
      {"tier": "small_parcel", "tier_label": "Small parcel", "sort_order": 5,
       "max_dims_mm": {"length": 350, "width": 250, "height": 120}, "max_unit_weight_g": 3900, "max_dimensional_weight_g": 2100,
       "from_weight_g": 900, "to_weight_g": 1400, "amount_minor": 305},
      {"tier": "small_parcel", "tier_label": "Small parcel", "sort_order": 5,
       "max_dims_mm": {"length": 350, "width": 250, "height": 120}, "max_unit_weight_g": 3900, "max_dimensional_weight_g": 2100,
       "from_weight_g": 1400, "to_weight_g": 1900, "amount_minor": 325},
      {"tier": "small_parcel", "tier_label": "Small parcel", "sort_order": 5,
       "max_dims_mm": {"length": 350, "width": 250, "height": 120}, "max_unit_weight_g": 3900, "max_dimensional_weight_g": 2100,
       "from_weight_g": 1900, "to_weight_g": 3900, "amount_minor": 327},

      {"tier": "standard_parcel", "tier_label": "Standard parcel", "sort_order": 6,
       "max_dims_mm": {"length": 450, "width": 340, "height": 260}, "max_unit_weight_g": 11900, "max_dimensional_weight_g": 7960,
       "from_weight_g": 0, "to_weight_g": 150, "amount_minor": 294},
      {"tier": "standard_parcel", "tier_label": "Standard parcel", "sort_order": 6,
       "max_dims_mm": {"length": 450, "width": 340, "height": 260}, "max_unit_weight_g": 11900, "max_dimensional_weight_g": 7960,
       "from_weight_g": 150, "to_weight_g": 400, "amount_minor": 301},
      {"tier": "standard_parcel", "tier_label": "Standard parcel", "sort_order": 6,
       "max_dims_mm": {"length": 450, "width": 340, "height": 260}, "max_unit_weight_g": 11900, "max_dimensional_weight_g": 7960,
       "from_weight_g": 400, "to_weight_g": 900, "amount_minor": 306},
      {"tier": "standard_parcel", "tier_label": "Standard parcel", "sort_order": 6,
       "max_dims_mm": {"length": 450, "width": 340, "height": 260}, "max_unit_weight_g": 11900, "max_dimensional_weight_g": 7960,
       "from_weight_g": 900, "to_weight_g": 1400, "amount_minor": 326},
      {"tier": "standard_parcel", "tier_label": "Standard parcel", "sort_order": 6,
       "max_dims_mm": {"length": 450, "width": 340, "height": 260}, "max_unit_weight_g": 11900, "max_dimensional_weight_g": 7960,
       "from_weight_g": 1400, "to_weight_g": 1900, "amount_minor": 348},
      {"tier": "standard_parcel", "tier_label": "Standard parcel", "sort_order": 6,
       "max_dims_mm": {"length": 450, "width": 340, "height": 260}, "max_unit_weight_g": 11900, "max_dimensional_weight_g": 7960,
       "from_weight_g": 1900, "to_weight_g": 2900, "amount_minor": 349},
      {"tier": "standard_parcel", "tier_label": "Standard parcel", "sort_order": 6,
       "max_dims_mm": {"length": 450, "width": 340, "height": 260}, "max_unit_weight_g": 11900, "max_dimensional_weight_g": 7960,
       "from_weight_g": 2900, "to_weight_g": 3900, "amount_minor": 354},
      {"tier": "standard_parcel", "tier_label": "Standard parcel", "sort_order": 6,
       "max_dims_mm": {"length": 450, "width": 340, "height": 260}, "max_unit_weight_g": 11900, "max_dimensional_weight_g": 7960,
       "from_weight_g": 3900, "to_weight_g": 5900, "amount_minor": 356},
      {"tier": "standard_parcel", "tier_label": "Standard parcel", "sort_order": 6,
       "max_dims_mm": {"length": 450, "width": 340, "height": 260}, "max_unit_weight_g": 11900, "max_dimensional_weight_g": 7960,
       "from_weight_g": 5900, "to_weight_g": 8900, "amount_minor": 357},
      {"tier": "standard_parcel", "tier_label": "Standard parcel", "sort_order": 6,
       "max_dims_mm": {"length": 450, "width": 340, "height": 260}, "max_unit_weight_g": 11900, "max_dimensional_weight_g": 7960,
       "from_weight_g": 8900, "to_weight_g": 11900, "amount_minor": 358},

      {"tier": "small_oversize", "tier_label": "Small oversize", "sort_order": 7,
       "max_dims_mm": {"length": 610, "width": 460, "height": 460}, "max_unit_weight_g": 1760, "max_dimensional_weight_g": 25820,
       "from_weight_g": 0, "to_weight_g": 760, "amount_minor": 349},
      {"tier": "small_oversize", "tier_label": "Small oversize", "sort_order": 7,
       "max_dims_mm": {"length": 610, "width": 460, "height": 460}, "max_unit_weight_g": 1760, "max_dimensional_weight_g": 25820,
       "from_weight_g": 760, "to_weight_g": 1760, "amount_minor": 349, "per_kg_over_minor": 25},

      {"tier": "standard_oversize_light", "tier_label": "Standard oversize light", "sort_order": 8,
       "max_dims_mm": {"length": 1010, "width": 600, "height": 600}, "max_unit_weight_g": 15000, "max_dimensional_weight_g": 72720,
       "from_weight_g": 0, "to_weight_g": 760, "amount_minor": 435},
      {"tier": "standard_oversize_light", "tier_label": "Standard oversize light", "sort_order": 8,
       "max_dims_mm": {"length": 1010, "width": 600, "height": 600}, "max_unit_weight_g": 15000, "max_dimensional_weight_g": 72720,
       "from_weight_g": 760, "to_weight_g": 15000, "amount_minor": 435, "per_kg_over_minor": 15},

      {"tier": "standard_oversize_heavy", "tier_label": "Standard oversize heavy", "sort_order": 9,
       "max_dims_mm": {"length": 1010, "width": 600, "height": 600}, "max_unit_weight_g": 23000, "max_dimensional_weight_g": 72720,
       "from_weight_g": 15000, "to_weight_g": 15760, "amount_minor": 658},
      {"tier": "standard_oversize_heavy", "tier_label": "Standard oversize heavy", "sort_order": 9,
       "max_dims_mm": {"length": 1010, "width": 600, "height": 600}, "max_unit_weight_g": 23000, "max_dimensional_weight_g": 72720,
       "from_weight_g": 15760, "to_weight_g": 23000, "amount_minor": 658, "per_kg_over_minor": 8},

      {"tier": "standard_oversize_large", "tier_label": "Standard oversize large", "sort_order": 10,
       "max_dims_mm": {"length": 1200, "width": 600, "height": 600}, "max_unit_weight_g": 23000, "max_dimensional_weight_g": 86400,
       "from_weight_g": 0, "to_weight_g": 760, "amount_minor": 567},
      {"tier": "standard_oversize_large", "tier_label": "Standard oversize large", "sort_order": 10,
       "max_dims_mm": {"length": 1200, "width": 600, "height": 600}, "max_unit_weight_g": 23000, "max_dimensional_weight_g": 86400,
       "from_weight_g": 760, "to_weight_g": 23000, "amount_minor": 567, "per_kg_over_minor": 7},

      {"tier": "bulky_oversize", "tier_label": "Bulky oversize", "sort_order": 11,
       "max_dims_mm": {"length": null, "width": null, "height": null}, "max_unit_weight_g": 23000, "max_dimensional_weight_g": 126000,
       "from_weight_g": 0, "to_weight_g": 760, "amount_minor": 1020},
      {"tier": "bulky_oversize", "tier_label": "Bulky oversize", "sort_order": 11,
       "max_dims_mm": {"length": null, "width": null, "height": null}, "max_unit_weight_g": 23000, "max_dimensional_weight_g": 126000,
       "from_weight_g": 760, "to_weight_g": 23000, "amount_minor": 1020, "per_kg_over_minor": 24},

      {"tier": "heavy_oversize", "tier_label": "Heavy oversize", "sort_order": 12,
       "max_dims_mm": {"length": null, "width": null, "height": null}, "max_unit_weight_g": 31500, "max_dimensional_weight_g": 126000,
       "from_weight_g": 23000, "to_weight_g": 31500, "amount_minor": 1304},
      {"tier": "heavy_oversize", "tier_label": "Heavy oversize", "sort_order": 12,
       "max_dims_mm": {"length": null, "width": null, "height": null}, "max_unit_weight_g": 31500, "max_dimensional_weight_g": 126000,
       "from_weight_g": 31500, "to_weight_g": 126000, "amount_minor": 1304, "per_kg_over_minor": 9},

      {"tier": "special_oversize", "tier_label": "Special oversize", "sort_order": 13,
       "max_dims_mm": {"length": null, "width": null, "height": null}, "max_unit_weight_g": null, "max_dimensional_weight_g": null,
       "from_weight_g": 0, "to_weight_g": 30000, "amount_minor": 1622},
      {"tier": "special_oversize", "tier_label": "Special oversize", "sort_order": 13,
       "max_dims_mm": {"length": null, "width": null, "height": null}, "max_unit_weight_g": null, "max_dimensional_weight_g": null,
       "from_weight_g": 30000, "to_weight_g": 40000, "amount_minor": 1724},
      {"tier": "special_oversize", "tier_label": "Special oversize", "sort_order": 13,
       "max_dims_mm": {"length": null, "width": null, "height": null}, "max_unit_weight_g": null, "max_dimensional_weight_g": null,
       "from_weight_g": 40000, "to_weight_g": 50000, "amount_minor": 3438},
      {"tier": "special_oversize", "tier_label": "Special oversize", "sort_order": 13,
       "max_dims_mm": {"length": null, "width": null, "height": null}, "max_unit_weight_g": null, "max_dimensional_weight_g": null,
       "from_weight_g": 50000, "to_weight_g": 60000, "amount_minor": 4204},
      {"tier": "special_oversize", "tier_label": "Special oversize", "sort_order": 13,
       "max_dims_mm": {"length": null, "width": null, "height": null}, "max_unit_weight_g": null, "max_dimensional_weight_g": null,
       "from_weight_g": 60000, "to_weight_g": null, "amount_minor": 4204, "per_kg_over_minor": 35}
    ]'::jsonb as fulfilment_bands,

    -- ---------------------------------------------------------------------
    -- UK monthly storage — rate card p.21. Billed per CUBIC FOOT in the UK.
    -- Storage utilisation and aged-inventory surcharges are account-level and
    -- depend on the seller's own inventory history, so they are not per-deal
    -- inputs and are not seeded here.
    -- ---------------------------------------------------------------------
    '{
      "unit": "cubic_foot",
      "currency": "GBP",
      "basis": "per_unit_volume_per_month",
      "periods": [
        {"code": "jan_sep", "label": "January-September", "from_month": 1,  "to_month": 9},
        {"code": "oct_dec", "label": "October-December",  "from_month": 10, "to_month": 12}
      ],
      "rates": [
        {"size_group": "standard", "category_group": "clothing_eyewear_footwear_bags", "dangerous_goods": false, "period": "jan_sep", "amount_minor": 62},
        {"size_group": "standard", "category_group": "clothing_eyewear_footwear_bags", "dangerous_goods": false, "period": "oct_dec", "amount_minor": 82},
        {"size_group": "standard", "category_group": "all_other",                      "dangerous_goods": false, "period": "jan_sep", "amount_minor": 76},
        {"size_group": "standard", "category_group": "all_other",                      "dangerous_goods": false, "period": "oct_dec", "amount_minor": 151},
        {"size_group": "oversize", "category_group": "all",                            "dangerous_goods": false, "period": "jan_sep", "amount_minor": 55},
        {"size_group": "oversize", "category_group": "all",                            "dangerous_goods": false, "period": "oct_dec", "amount_minor": 87},
        {"size_group": "standard", "category_group": "all",                            "dangerous_goods": true,  "period": "jan_sep", "amount_minor": 74},
        {"size_group": "standard", "category_group": "all",                            "dangerous_goods": true,  "period": "oct_dec", "amount_minor": 130},
        {"size_group": "oversize", "category_group": "all",                            "dangerous_goods": true,  "period": "jan_sep", "amount_minor": 70},
        {"size_group": "oversize", "category_group": "all",                            "dangerous_goods": true,  "period": "oct_dec", "amount_minor": 111}
      ],
      "default_expected_months": 1,
      "notes": "Base monthly storage only. The storage utilisation surcharge and the FBA aged inventory surcharge are account-level and history-dependent, not per-deal, and are deliberately absent."
    }'::jsonb as storage_rules
)
insert into public.fee_schedules (
  id, marketplace_id, version, effective_from, effective_to,
  referral_rules, fulfilment_bands, storage_rules, surcharges,
  currency, source_url, verified_at
)
select
  -- Explicit casts: INSERT ... SELECT does not infer a literal's type from the
  -- target column the way INSERT ... VALUES does.
  '5eed0006-0000-4000-8000-000000000001'::uuid,
  '5eed0003-0000-4000-8000-000000000001'::uuid,
  '2026-02-01',
  date '2026-02-01', date '2026-04-17',
  uk.referral_rules, uk.fulfilment_bands, uk.storage_rules,
  '[
    {"code": "digital_services_fee", "label": "Digital Services Fee", "basis": "selling_fees", "rate_bps": 200,
     "applies_to_countries": ["GB"],
     "notes": "2% of Selling on Amazon fees plus FBA fees, for UK-established sellers on amazon.co.uk. Charged since 2024-10-01."},
    {"code": "media_closing_fee", "label": "Media closing fee", "basis": "flat", "amount_minor": 50,
     "applies_to_categories": ["books", "music_video_and_dvd", "video_games_and_gaming_accessories", "video_game_consoles", "software"],
     "notes": "GBP 0.50 per media item sold (rate card referral-fee footnote 3)."}
  ]'::jsonb,
  'GBP',
  'https://m.media-amazon.com/images/G/02/sell/images/260114-FBA-Rate-Card-EN.pdf',
  timestamptz '2026-08-11T00:00:00Z'
from uk
union all
select
  '5eed0006-0000-4000-8000-000000000002'::uuid,
  '5eed0003-0000-4000-8000-000000000001'::uuid,
  '2026-04-17',
  date '2026-04-17', null::date,
  uk.referral_rules, uk.fulfilment_bands, uk.storage_rules,
  '[
    {"code": "digital_services_fee", "label": "Digital Services Fee", "basis": "selling_fees", "rate_bps": 200,
     "applies_to_countries": ["GB"],
     "notes": "2% of Selling on Amazon fees plus FBA fees, for UK-established sellers on amazon.co.uk. The separate 3% rate announced for 2026-03-20 applies to a UK-established seller selling into the FR, IT and ES stores, which is cross-border and out of MVP scope; the amazon.co.uk rate remains 2%. Corroborated from secondary sources only - MARKET_PLAYBOOK.md requires confirmation against a real Seller Central invoice before beta."},
    {"code": "fuel_and_logistics_surcharge", "label": "Fuel and logistics-related surcharge", "basis": "fulfilment_fee", "rate_bps": 150,
     "notes": "1.5% of fulfilment fees across FBA in the UK from 2026-04-17 (rate card p.6 note). The US and CA equivalent is 3.5% and does not apply here."},
    {"code": "media_closing_fee", "label": "Media closing fee", "basis": "flat", "amount_minor": 50,
     "applies_to_categories": ["books", "music_video_and_dvd", "video_games_and_gaming_accessories", "video_game_consoles", "software"],
     "notes": "GBP 0.50 per media item sold (rate card referral-fee footnote 3). The rate card states a GBP 0.25 minimum referral fee for ALL categories; sell.amazon.co.uk states Books, Music, Video, DVD and Grocery are exempt from the minimum. The rate card is taken as primary and the conflict is a MARKET_PLAYBOOK.md verification item."}
  ]'::jsonb,
  'GBP',
  'https://m.media-amazon.com/images/G/02/sell/images/260630-FBA-Rate-Card-EN1.pdf',
  timestamptz '2026-08-11T00:00:00Z'
from uk
on conflict (marketplace_id, version) do update set
  effective_from   = excluded.effective_from,
  effective_to     = excluded.effective_to,
  referral_rules   = excluded.referral_rules,
  fulfilment_bands = excluded.fulfilment_bands,
  storage_rules    = excluded.storage_rules,
  surcharges       = excluded.surcharges,
  currency         = excluded.currency,
  source_url       = excluded.source_url,
  verified_at      = excluded.verified_at;

-- ---------------------------------------------------------------------------
-- amazon_de — the synthetic second market's schedule.
-- ---------------------------------------------------------------------------
--
-- UNVERIFIED, AND `verified_at` IS NULL TO SAY SO.
--
-- This exists so the second market resolves end to end through the shape
-- MarketContext will use — a market with no fee schedule is not a demonstration
-- of anything. The referral percentages are the same column of the same rate
-- card as the UK rows (Amazon prints "UK/DE/FR/IT/ES" as one column with the
-- £/€ pair written per row), so the rates are as sound as the UK ones and only
-- the thresholds differ. What is NOT resolved, and what keeps verified_at NULL:
--
--   * DE fulfilment has two competing columns on p.6 — "DE Only" and the
--     Central Europe Programme (DE/PL/CZ) — and which applies depends on
--     whether the seller is enrolled in CEP. Only the "DE Only" envelope and
--     parcel tiers are seeded; the oversize tiers are absent.
--   * Pan-EU per-unit surcharges (p.10) are not modelled.
--   * marketplace_fees_taxed for DE assumes the Luxembourg reverse charge.
--
-- Those gaps are safe only because the DE market is `planned` and inactive and
-- docs/MARKET_PLAYBOOK.md gates a live flip on a non-NULL verified_at. They
-- would not be safe in a live market, which is the point of recording them.

insert into public.fee_schedules (
  id, marketplace_id, version, effective_from, effective_to,
  referral_rules, fulfilment_bands, storage_rules, surcharges,
  currency, source_url, verified_at
) values
(
  '5eed0006-0000-4000-8000-000000000003',
  '5eed0003-0000-4000-8000-000000000002',
  '2026-07-01',
  date '2026-07-01', null,
  '[
    {"code": "amazon_device_accessories", "label": "Amazon Device Accessories", "mode": "flat", "min_fee_minor": 30,
     "tiers": [{"up_to_minor": null, "rate_bps": 4500}]},
    {"code": "automotive_and_powersports", "label": "Automotive and Powersports", "mode": "marginal", "min_fee_minor": 30,
     "tiers": [{"up_to_minor": 5000, "rate_bps": 1500}, {"up_to_minor": null, "rate_bps": 900}]},
    {"code": "baby_products", "label": "Baby Products", "mode": "threshold", "min_fee_minor": 30,
     "tiers": [{"up_to_minor": 1000, "rate_bps": 800}, {"up_to_minor": null, "rate_bps": 1500}]},
    {"code": "baby_pushchairs_and_safety_equipment", "label": "Baby Pushchairs and Safety Equipment", "mode": "threshold", "min_fee_minor": 30,
     "tiers": [{"up_to_minor": 1000, "rate_bps": 800}, {"up_to_minor": null, "rate_bps": 1500}]},
    {"code": "beauty_health_and_personal_care", "label": "Beauty, Health and Personal Care; Personal care appliances", "mode": "threshold", "min_fee_minor": 30,
     "tiers": [{"up_to_minor": 1000, "rate_bps": 800}, {"up_to_minor": null, "rate_bps": 1500}]},
    {"code": "clothing_and_accessories", "label": "Clothing and Accessories", "mode": "threshold", "min_fee_minor": 30,
     "tiers": [{"up_to_minor": 1500, "rate_bps": 500}, {"up_to_minor": 2000, "rate_bps": 1000}, {"up_to_minor": null, "rate_bps": 1500}]},
    {"code": "computers", "label": "Computers", "mode": "flat", "min_fee_minor": 30,
     "tiers": [{"up_to_minor": null, "rate_bps": 700}]},
    {"code": "consumer_electronics", "label": "Consumer Electronics", "mode": "flat", "min_fee_minor": 30,
     "tiers": [{"up_to_minor": null, "rate_bps": 700}]},
    {"code": "electronic_accessories_and_computer_accessories", "label": "Electronic Accessories; Computer accessories", "mode": "marginal", "min_fee_minor": 30,
     "tiers": [{"up_to_minor": 10000, "rate_bps": 1500}, {"up_to_minor": null, "rate_bps": 800}]},
    {"code": "full_size_appliances", "label": "Full-Size Appliances", "mode": "flat", "min_fee_minor": 30,
     "tiers": [{"up_to_minor": null, "rate_bps": 700}]},
    {"code": "furniture", "label": "Furniture", "mode": "marginal", "min_fee_minor": 30,
     "tiers": [{"up_to_minor": 20000, "rate_bps": 1500}, {"up_to_minor": null, "rate_bps": 1000}]},
    {"code": "grocery_and_gourmet", "label": "Grocery and Gourmet", "mode": "threshold", "min_fee_minor": 30,
     "tiers": [{"up_to_minor": 1000, "rate_bps": 500}, {"up_to_minor": null, "rate_bps": 1500}]},
    {"code": "home_products", "label": "Home Products", "mode": "threshold", "min_fee_minor": 30,
     "tiers": [{"up_to_minor": 2000, "rate_bps": 800}, {"up_to_minor": null, "rate_bps": 1500}]},
    {"code": "jewellery", "label": "Jewellery", "mode": "marginal", "min_fee_minor": 30,
     "tiers": [{"up_to_minor": 25000, "rate_bps": 2000}, {"up_to_minor": null, "rate_bps": 500}]},
    {"code": "tools_and_home_improvement", "label": "Tools and Home Improvement", "mode": "flat", "min_fee_minor": 30,
     "tiers": [{"up_to_minor": null, "rate_bps": 1300}]},
    {"code": "tyres", "label": "Tyres", "mode": "flat", "min_fee_minor": 30,
     "tiers": [{"up_to_minor": null, "rate_bps": 700}]},
    {"code": "video_game_consoles", "label": "Video Game Consoles", "mode": "flat", "min_fee_minor": 30,
     "tiers": [{"up_to_minor": null, "rate_bps": 800}]},
    {"code": "watches", "label": "Watches", "mode": "marginal", "min_fee_minor": 30,
     "tiers": [{"up_to_minor": 25000, "rate_bps": 1500}, {"up_to_minor": null, "rate_bps": 500}]},
    {"code": "everything_else", "label": "Everything else", "mode": "flat", "min_fee_minor": 30, "default": true,
     "tiers": [{"up_to_minor": null, "rate_bps": 1500}]}
  ]'::jsonb,
  '[
    {"tier": "light_envelope", "tier_label": "Light envelope", "sort_order": 1,
     "max_dims_mm": {"length": 330, "width": 230, "height": 25}, "max_unit_weight_g": 100, "max_dimensional_weight_g": null,
     "from_weight_g": 0, "to_weight_g": 20, "amount_minor": 233},
    {"tier": "light_envelope", "tier_label": "Light envelope", "sort_order": 1,
     "max_dims_mm": {"length": 330, "width": 230, "height": 25}, "max_unit_weight_g": 100, "max_dimensional_weight_g": null,
     "from_weight_g": 20, "to_weight_g": 40, "amount_minor": 237},
    {"tier": "light_envelope", "tier_label": "Light envelope", "sort_order": 1,
     "max_dims_mm": {"length": 330, "width": 230, "height": 25}, "max_unit_weight_g": 100, "max_dimensional_weight_g": null,
     "from_weight_g": 40, "to_weight_g": 60, "amount_minor": 239},
    {"tier": "light_envelope", "tier_label": "Light envelope", "sort_order": 1,
     "max_dims_mm": {"length": 330, "width": 230, "height": 25}, "max_unit_weight_g": 100, "max_dimensional_weight_g": null,
     "from_weight_g": 60, "to_weight_g": 80, "amount_minor": 252},
    {"tier": "light_envelope", "tier_label": "Light envelope", "sort_order": 1,
     "max_dims_mm": {"length": 330, "width": 230, "height": 25}, "max_unit_weight_g": 100, "max_dimensional_weight_g": null,
     "from_weight_g": 80, "to_weight_g": 100, "amount_minor": 254},
    {"tier": "standard_envelope", "tier_label": "Standard envelope", "sort_order": 2,
     "max_dims_mm": {"length": 330, "width": 230, "height": 25}, "max_unit_weight_g": 460, "max_dimensional_weight_g": null,
     "from_weight_g": 100, "to_weight_g": 210, "amount_minor": 257},
    {"tier": "standard_envelope", "tier_label": "Standard envelope", "sort_order": 2,
     "max_dims_mm": {"length": 330, "width": 230, "height": 25}, "max_unit_weight_g": 460, "max_dimensional_weight_g": null,
     "from_weight_g": 210, "to_weight_g": 460, "amount_minor": 268},
    {"tier": "large_envelope", "tier_label": "Large envelope", "sort_order": 3,
     "max_dims_mm": {"length": 330, "width": 230, "height": 40}, "max_unit_weight_g": 960, "max_dimensional_weight_g": null,
     "from_weight_g": 0, "to_weight_g": 960, "amount_minor": 304},
    {"tier": "extra_large_envelope", "tier_label": "Extra-large envelope", "sort_order": 4,
     "max_dims_mm": {"length": 330, "width": 230, "height": 60}, "max_unit_weight_g": 960, "max_dimensional_weight_g": null,
     "from_weight_g": 0, "to_weight_g": 960, "amount_minor": 342}
  ]'::jsonb,
  '{
    "unit": "cubic_metre",
    "currency": "EUR",
    "basis": "per_unit_volume_per_month",
    "periods": [
      {"code": "jan_sep", "label": "January-September", "from_month": 1,  "to_month": 9},
      {"code": "oct_dec", "label": "October-December",  "from_month": 10, "to_month": 12}
    ],
    "rates": [
      {"size_group": "standard", "category_group": "clothing_eyewear_footwear_bags", "dangerous_goods": false, "period": "jan_sep", "amount_minor": 1999},
      {"size_group": "standard", "category_group": "clothing_eyewear_footwear_bags", "dangerous_goods": false, "period": "oct_dec", "amount_minor": 2923},
      {"size_group": "standard", "category_group": "all_other",                      "dangerous_goods": false, "period": "jan_sep", "amount_minor": 2754},
      {"size_group": "standard", "category_group": "all_other",                      "dangerous_goods": false, "period": "oct_dec", "amount_minor": 5220},
      {"size_group": "oversize", "category_group": "all",                            "dangerous_goods": false, "period": "jan_sep", "amount_minor": 2178},
      {"size_group": "oversize", "category_group": "all",                            "dangerous_goods": false, "period": "oct_dec", "amount_minor": 3449},
      {"size_group": "standard", "category_group": "all",                            "dangerous_goods": true,  "period": "jan_sep", "amount_minor": 3000},
      {"size_group": "standard", "category_group": "all",                            "dangerous_goods": true,  "period": "oct_dec", "amount_minor": 5051},
      {"size_group": "oversize", "category_group": "all",                            "dangerous_goods": true,  "period": "jan_sep", "amount_minor": 2750},
      {"size_group": "oversize", "category_group": "all",                            "dangerous_goods": true,  "period": "oct_dec", "amount_minor": 4389}
    ],
    "default_expected_months": 1,
    "notes": "Per cubic METRE, unlike the UK. This is exactly why storage_rules.unit is data."
  }'::jsonb,
  '[
    {"code": "fuel_and_logistics_surcharge", "label": "Fuel and logistics-related surcharge", "basis": "fulfilment_fee", "rate_bps": 150,
     "notes": "1.5% of fulfilment fees, DE included, from 2026-04-17."}
  ]'::jsonb,
  'EUR',
  'https://m.media-amazon.com/images/G/02/sell/images/260630-FBA-Rate-Card-EN1.pdf',
  null
)
on conflict (marketplace_id, version) do update set
  effective_from   = excluded.effective_from,
  effective_to     = excluded.effective_to,
  referral_rules   = excluded.referral_rules,
  fulfilment_bands = excluded.fulfilment_bands,
  storage_rules    = excluded.storage_rules,
  surcharges       = excluded.surcharges,
  currency         = excluded.currency,
  source_url       = excluded.source_url,
  verified_at      = excluded.verified_at;
