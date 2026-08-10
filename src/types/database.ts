export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.15"
  }
  public: {
    Tables: {
      barcode_lookups: {
        Row: {
          barcode_raw: string
          created_at: string
          credits_spent: number
          gtin14: string | null
          id: string
          market_id: string
          resolved_marketplace_product_id: string | null
          result: Json | null
          updated_at: string
          user_id: string
        }
        Insert: {
          barcode_raw: string
          created_at?: string
          credits_spent?: number
          gtin14?: string | null
          id?: string
          market_id: string
          resolved_marketplace_product_id?: string | null
          result?: Json | null
          updated_at?: string
          user_id: string
        }
        Update: {
          barcode_raw?: string
          created_at?: string
          credits_spent?: number
          gtin14?: string | null
          id?: string
          market_id?: string
          resolved_marketplace_product_id?: string | null
          result?: Json | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "barcode_lookups_market_id_fkey"
            columns: ["market_id"]
            isOneToOne: false
            referencedRelation: "markets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "barcode_lookups_resolved_marketplace_product_id_fkey"
            columns: ["resolved_marketplace_product_id"]
            isOneToOne: false
            referencedRelation: "marketplace_products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "barcode_lookups_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      countries: {
        Row: {
          active: boolean
          code: string
          created_at: string
          default_currency: string
          default_locale: string
          name: string
          retail_price_display: Database["public"]["Enums"]["price_tax_treatment"]
          tax_regime: Database["public"]["Enums"]["tax_regime"]
          timezone_default: string
          updated_at: string
        }
        Insert: {
          active?: boolean
          code: string
          created_at?: string
          default_currency: string
          default_locale: string
          name: string
          retail_price_display: Database["public"]["Enums"]["price_tax_treatment"]
          tax_regime: Database["public"]["Enums"]["tax_regime"]
          timezone_default: string
          updated_at?: string
        }
        Update: {
          active?: boolean
          code?: string
          created_at?: string
          default_currency?: string
          default_locale?: string
          name?: string
          retail_price_display?: Database["public"]["Enums"]["price_tax_treatment"]
          tax_regime?: Database["public"]["Enums"]["tax_regime"]
          timezone_default?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "countries_default_currency_fkey"
            columns: ["default_currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      currencies: {
        Row: {
          code: string
          created_at: string
          minor_unit_exponent: number
          name: string
          symbol: string | null
          updated_at: string
        }
        Insert: {
          code: string
          created_at?: string
          minor_unit_exponent: number
          name: string
          symbol?: string | null
          updated_at?: string
        }
        Update: {
          code?: string
          created_at?: string
          minor_unit_exponent?: number
          name?: string
          symbol?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      deal_unlocks: {
        Row: {
          created_at: string
          credits_spent: number
          deal_id: string
          id: string
          unlocked_at: string
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          credits_spent: number
          deal_id: string
          id?: string
          unlocked_at?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          credits_spent?: number
          deal_id?: string
          id?: string
          unlocked_at?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "deal_unlocks_deal_id_fkey"
            columns: ["deal_id"]
            isOneToOne: false
            referencedRelation: "deals"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "deal_unlocks_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      deals: {
        Row: {
          buy_price_minor: number
          buy_price_tax_treatment: Database["public"]["Enums"]["price_tax_treatment"]
          buy_tax_reclaim_minor: number
          calc_version: string
          competition_band: Database["public"]["Enums"]["component_band"]
          computed_at: string
          confidence_band: Database["public"]["Enums"]["component_band"]
          created_at: string
          currency: string
          deal_score: number
          demand_band: Database["public"]["Enums"]["component_band"]
          expires_at: string | null
          fee_schedule_id: string
          fulfilment_fee_minor: number
          id: string
          inbound_shipping_minor: number
          inputs_snapshot: Json
          margin_bps: number
          market_id: string
          marketplace_id: string
          marketplace_product_id: string
          match_confidence: number
          net_profit_minor: number
          other_fees_minor: number
          prep_cost_minor: number
          published_at: string | null
          published_by: string | null
          referral_fee_minor: number
          retailer_id: string
          retailer_product_id: string
          retire_reason: string | null
          retired_at: string | null
          retired_by: string | null
          roi_bps: number
          score_breakdown: Json
          score_version: string
          sell_price_minor: number
          sell_tax_liability_minor: number
          stability_band: Database["public"]["Enums"]["component_band"]
          status: Database["public"]["Enums"]["deal_status"]
          storage_fee_minor: number
          surcharges: Json
          tax_schedule_id: string
          updated_at: string
        }
        Insert: {
          buy_price_minor: number
          buy_price_tax_treatment: Database["public"]["Enums"]["price_tax_treatment"]
          buy_tax_reclaim_minor?: number
          calc_version: string
          competition_band: Database["public"]["Enums"]["component_band"]
          computed_at?: string
          confidence_band: Database["public"]["Enums"]["component_band"]
          created_at?: string
          currency: string
          deal_score: number
          demand_band: Database["public"]["Enums"]["component_band"]
          expires_at?: string | null
          fee_schedule_id: string
          fulfilment_fee_minor?: number
          id?: string
          inbound_shipping_minor?: number
          inputs_snapshot: Json
          margin_bps: number
          market_id: string
          marketplace_id: string
          marketplace_product_id: string
          match_confidence: number
          net_profit_minor: number
          other_fees_minor?: number
          prep_cost_minor?: number
          published_at?: string | null
          published_by?: string | null
          referral_fee_minor?: number
          retailer_id: string
          retailer_product_id: string
          retire_reason?: string | null
          retired_at?: string | null
          retired_by?: string | null
          roi_bps: number
          score_breakdown: Json
          score_version: string
          sell_price_minor: number
          sell_tax_liability_minor?: number
          stability_band: Database["public"]["Enums"]["component_band"]
          status?: Database["public"]["Enums"]["deal_status"]
          storage_fee_minor?: number
          surcharges?: Json
          tax_schedule_id: string
          updated_at?: string
        }
        Update: {
          buy_price_minor?: number
          buy_price_tax_treatment?: Database["public"]["Enums"]["price_tax_treatment"]
          buy_tax_reclaim_minor?: number
          calc_version?: string
          competition_band?: Database["public"]["Enums"]["component_band"]
          computed_at?: string
          confidence_band?: Database["public"]["Enums"]["component_band"]
          created_at?: string
          currency?: string
          deal_score?: number
          demand_band?: Database["public"]["Enums"]["component_band"]
          expires_at?: string | null
          fee_schedule_id?: string
          fulfilment_fee_minor?: number
          id?: string
          inbound_shipping_minor?: number
          inputs_snapshot?: Json
          margin_bps?: number
          market_id?: string
          marketplace_id?: string
          marketplace_product_id?: string
          match_confidence?: number
          net_profit_minor?: number
          other_fees_minor?: number
          prep_cost_minor?: number
          published_at?: string | null
          published_by?: string | null
          referral_fee_minor?: number
          retailer_id?: string
          retailer_product_id?: string
          retire_reason?: string | null
          retired_at?: string | null
          retired_by?: string | null
          roi_bps?: number
          score_breakdown?: Json
          score_version?: string
          sell_price_minor?: number
          sell_tax_liability_minor?: number
          stability_band?: Database["public"]["Enums"]["component_band"]
          status?: Database["public"]["Enums"]["deal_status"]
          storage_fee_minor?: number
          surcharges?: Json
          tax_schedule_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "deals_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "deals_fee_schedule_id_fkey"
            columns: ["fee_schedule_id"]
            isOneToOne: false
            referencedRelation: "fee_schedules"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "deals_market_currency_fkey"
            columns: ["market_id", "currency"]
            isOneToOne: false
            referencedRelation: "markets"
            referencedColumns: ["id", "currency"]
          },
          {
            foreignKeyName: "deals_market_marketplace_fkey"
            columns: ["market_id", "marketplace_id"]
            isOneToOne: false
            referencedRelation: "markets"
            referencedColumns: ["id", "marketplace_id"]
          },
          {
            foreignKeyName: "deals_marketplace_product_fkey"
            columns: ["marketplace_product_id", "marketplace_id"]
            isOneToOne: false
            referencedRelation: "marketplace_products"
            referencedColumns: ["id", "marketplace_id"]
          },
          {
            foreignKeyName: "deals_retailer_market_fkey"
            columns: ["retailer_id", "market_id"]
            isOneToOne: false
            referencedRelation: "retailers"
            referencedColumns: ["id", "market_id"]
          },
          {
            foreignKeyName: "deals_retailer_product_fkey"
            columns: ["retailer_product_id", "retailer_id"]
            isOneToOne: false
            referencedRelation: "retailer_products"
            referencedColumns: ["id", "retailer_id"]
          },
          {
            foreignKeyName: "deals_tax_schedule_id_fkey"
            columns: ["tax_schedule_id"]
            isOneToOne: false
            referencedRelation: "tax_schedules"
            referencedColumns: ["id"]
          },
        ]
      }
      fee_schedules: {
        Row: {
          created_at: string
          currency: string
          effective_from: string
          effective_to: string | null
          fulfilment_bands: Json
          id: string
          marketplace_id: string
          referral_rules: Json
          source_url: string | null
          storage_rules: Json
          surcharges: Json
          updated_at: string
          verified_at: string | null
          version: string
        }
        Insert: {
          created_at?: string
          currency: string
          effective_from: string
          effective_to?: string | null
          fulfilment_bands?: Json
          id?: string
          marketplace_id: string
          referral_rules?: Json
          source_url?: string | null
          storage_rules?: Json
          surcharges?: Json
          updated_at?: string
          verified_at?: string | null
          version: string
        }
        Update: {
          created_at?: string
          currency?: string
          effective_from?: string
          effective_to?: string | null
          fulfilment_bands?: Json
          id?: string
          marketplace_id?: string
          referral_rules?: Json
          source_url?: string | null
          storage_rules?: Json
          surcharges?: Json
          updated_at?: string
          verified_at?: string | null
          version?: string
        }
        Relationships: [
          {
            foreignKeyName: "fee_schedules_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "fee_schedules_marketplace_id_fkey"
            columns: ["marketplace_id"]
            isOneToOne: false
            referencedRelation: "marketplaces"
            referencedColumns: ["id"]
          },
        ]
      }
      marketplace_products: {
        Row: {
          brand: string | null
          buybox_is_marketplace_owned: boolean | null
          buybox_price_minor: number | null
          category_id: string | null
          category_path: string | null
          created_at: string
          currency: string
          dims_mm: Json | null
          est_monthly_sales: number | null
          external_id: string
          gtins: string[]
          hazmat: boolean | null
          id: string
          image_key: string | null
          item_weight_g: number | null
          listing_url: string | null
          marketplace_id: string
          marketplace_owned_in_stock_pct_90d: number | null
          offer_count_marketplace_fulfilled: number | null
          offer_count_seller_fulfilled: number | null
          oversize: boolean | null
          price_avg_90d_minor: number | null
          price_max_90d_minor: number | null
          price_min_90d_minor: number | null
          price_stddev_90d_minor: number | null
          provider_key: string
          provider_raw: Json | null
          rank_avg_90d: number | null
          rank_value: number | null
          refreshed_at: string
          restricted_flags: Json | null
          title: string | null
          updated_at: string
        }
        Insert: {
          brand?: string | null
          buybox_is_marketplace_owned?: boolean | null
          buybox_price_minor?: number | null
          category_id?: string | null
          category_path?: string | null
          created_at?: string
          currency: string
          dims_mm?: Json | null
          est_monthly_sales?: number | null
          external_id: string
          gtins?: string[]
          hazmat?: boolean | null
          id?: string
          image_key?: string | null
          item_weight_g?: number | null
          listing_url?: string | null
          marketplace_id: string
          marketplace_owned_in_stock_pct_90d?: number | null
          offer_count_marketplace_fulfilled?: number | null
          offer_count_seller_fulfilled?: number | null
          oversize?: boolean | null
          price_avg_90d_minor?: number | null
          price_max_90d_minor?: number | null
          price_min_90d_minor?: number | null
          price_stddev_90d_minor?: number | null
          provider_key: string
          provider_raw?: Json | null
          rank_avg_90d?: number | null
          rank_value?: number | null
          refreshed_at?: string
          restricted_flags?: Json | null
          title?: string | null
          updated_at?: string
        }
        Update: {
          brand?: string | null
          buybox_is_marketplace_owned?: boolean | null
          buybox_price_minor?: number | null
          category_id?: string | null
          category_path?: string | null
          created_at?: string
          currency?: string
          dims_mm?: Json | null
          est_monthly_sales?: number | null
          external_id?: string
          gtins?: string[]
          hazmat?: boolean | null
          id?: string
          image_key?: string | null
          item_weight_g?: number | null
          listing_url?: string | null
          marketplace_id?: string
          marketplace_owned_in_stock_pct_90d?: number | null
          offer_count_marketplace_fulfilled?: number | null
          offer_count_seller_fulfilled?: number | null
          oversize?: boolean | null
          price_avg_90d_minor?: number | null
          price_max_90d_minor?: number | null
          price_min_90d_minor?: number | null
          price_stddev_90d_minor?: number | null
          provider_key?: string
          provider_raw?: Json | null
          rank_avg_90d?: number | null
          rank_value?: number | null
          refreshed_at?: string
          restricted_flags?: Json | null
          title?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "marketplace_products_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "marketplace_products_currency_matches_marketplace"
            columns: ["marketplace_id", "currency"]
            isOneToOne: false
            referencedRelation: "marketplaces"
            referencedColumns: ["id", "currency"]
          },
          {
            foreignKeyName: "marketplace_products_marketplace_id_fkey"
            columns: ["marketplace_id"]
            isOneToOne: false
            referencedRelation: "marketplaces"
            referencedColumns: ["id"]
          },
        ]
      }
      marketplaces: {
        Row: {
          active: boolean
          adapter_key: string
          capabilities: Json
          code: string
          country_code: string
          created_at: string
          currency: string
          domain: string
          fulfilment_programs: Json
          id: string
          provider: string
          updated_at: string
        }
        Insert: {
          active?: boolean
          adapter_key: string
          capabilities?: Json
          code: string
          country_code: string
          created_at?: string
          currency: string
          domain: string
          fulfilment_programs?: Json
          id?: string
          provider: string
          updated_at?: string
        }
        Update: {
          active?: boolean
          adapter_key?: string
          capabilities?: Json
          code?: string
          country_code?: string
          created_at?: string
          currency?: string
          domain?: string
          fulfilment_programs?: Json
          id?: string
          provider?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "marketplaces_country_code_fkey"
            columns: ["country_code"]
            isOneToOne: false
            referencedRelation: "countries"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "marketplaces_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      markets: {
        Row: {
          active: boolean
          created_at: string
          currency: string
          id: string
          launch_status: Database["public"]["Enums"]["market_launch_status"]
          marketplace_id: string
          slug: string
          source_country_code: string
          updated_at: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          currency: string
          id?: string
          launch_status?: Database["public"]["Enums"]["market_launch_status"]
          marketplace_id: string
          slug: string
          source_country_code: string
          updated_at?: string
        }
        Update: {
          active?: boolean
          created_at?: string
          currency?: string
          id?: string
          launch_status?: Database["public"]["Enums"]["market_launch_status"]
          marketplace_id?: string
          slug?: string
          source_country_code?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "markets_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "markets_currency_matches_marketplace"
            columns: ["marketplace_id", "currency"]
            isOneToOne: false
            referencedRelation: "marketplaces"
            referencedColumns: ["id", "currency"]
          },
          {
            foreignKeyName: "markets_marketplace_id_fkey"
            columns: ["marketplace_id"]
            isOneToOne: false
            referencedRelation: "marketplaces"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "markets_source_country_code_fkey"
            columns: ["source_country_code"]
            isOneToOne: false
            referencedRelation: "countries"
            referencedColumns: ["code"]
          },
        ]
      }
      product_matches: {
        Row: {
          confidence: number
          created_at: string
          id: string
          marketplace_product_id: string
          method: Database["public"]["Enums"]["match_method"]
          retailer_product_id: string
          updated_at: string
          verified_by: Database["public"]["Enums"]["match_verified_by"]
        }
        Insert: {
          confidence: number
          created_at?: string
          id?: string
          marketplace_product_id: string
          method: Database["public"]["Enums"]["match_method"]
          retailer_product_id: string
          updated_at?: string
          verified_by?: Database["public"]["Enums"]["match_verified_by"]
        }
        Update: {
          confidence?: number
          created_at?: string
          id?: string
          marketplace_product_id?: string
          method?: Database["public"]["Enums"]["match_method"]
          retailer_product_id?: string
          updated_at?: string
          verified_by?: Database["public"]["Enums"]["match_verified_by"]
        }
        Relationships: [
          {
            foreignKeyName: "product_matches_marketplace_product_id_fkey"
            columns: ["marketplace_product_id"]
            isOneToOne: false
            referencedRelation: "marketplace_products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_matches_retailer_product_id_fkey"
            columns: ["retailer_product_id"]
            isOneToOne: false
            referencedRelation: "retailer_products"
            referencedColumns: ["id"]
          },
        ]
      }
      profiles: {
        Row: {
          assumption_currency: string | null
          country_code: string | null
          created_at: string
          credit_balance: number
          default_budget_minor: number | null
          default_fulfilment: Database["public"]["Enums"]["fulfilment_type"]
          default_market_id: string | null
          display_name: string | null
          id: string
          inbound_shipping_per_unit_minor: number | null
          locale: string | null
          onboarded_at: string | null
          prep_cost_per_unit_minor: number | null
          tax_registered: boolean
          tax_registration_country: string | null
          tax_scheme: Database["public"]["Enums"]["tax_scheme"]
          timezone: string | null
          updated_at: string
        }
        Insert: {
          assumption_currency?: string | null
          country_code?: string | null
          created_at?: string
          credit_balance?: number
          default_budget_minor?: number | null
          default_fulfilment?: Database["public"]["Enums"]["fulfilment_type"]
          default_market_id?: string | null
          display_name?: string | null
          id: string
          inbound_shipping_per_unit_minor?: number | null
          locale?: string | null
          onboarded_at?: string | null
          prep_cost_per_unit_minor?: number | null
          tax_registered?: boolean
          tax_registration_country?: string | null
          tax_scheme?: Database["public"]["Enums"]["tax_scheme"]
          timezone?: string | null
          updated_at?: string
        }
        Update: {
          assumption_currency?: string | null
          country_code?: string | null
          created_at?: string
          credit_balance?: number
          default_budget_minor?: number | null
          default_fulfilment?: Database["public"]["Enums"]["fulfilment_type"]
          default_market_id?: string | null
          display_name?: string | null
          id?: string
          inbound_shipping_per_unit_minor?: number | null
          locale?: string | null
          onboarded_at?: string | null
          prep_cost_per_unit_minor?: number | null
          tax_registered?: boolean
          tax_registration_country?: string | null
          tax_scheme?: Database["public"]["Enums"]["tax_scheme"]
          timezone?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "profiles_assumption_currency_fkey"
            columns: ["assumption_currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "profiles_country_code_fkey"
            columns: ["country_code"]
            isOneToOne: false
            referencedRelation: "countries"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "profiles_default_market_id_fkey"
            columns: ["default_market_id"]
            isOneToOne: false
            referencedRelation: "markets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "profiles_tax_registration_country_fkey"
            columns: ["tax_registration_country"]
            isOneToOne: false
            referencedRelation: "countries"
            referencedColumns: ["code"]
          },
        ]
      }
      purchase_records: {
        Row: {
          actual_buy_price_minor: number | null
          actual_profit_minor: number | null
          actual_sale_price_minor: number | null
          created_at: string
          currency: string
          deal_id: string
          expected_profit_minor: number
          id: string
          inputs_snapshot: Json
          market_id: string
          notes: string | null
          outcome: Database["public"]["Enums"]["purchase_outcome"]
          purchased_at: string
          units: number
          updated_at: string
          user_id: string
        }
        Insert: {
          actual_buy_price_minor?: number | null
          actual_profit_minor?: number | null
          actual_sale_price_minor?: number | null
          created_at?: string
          currency: string
          deal_id: string
          expected_profit_minor: number
          id?: string
          inputs_snapshot: Json
          market_id: string
          notes?: string | null
          outcome?: Database["public"]["Enums"]["purchase_outcome"]
          purchased_at?: string
          units: number
          updated_at?: string
          user_id: string
        }
        Update: {
          actual_buy_price_minor?: number | null
          actual_profit_minor?: number | null
          actual_sale_price_minor?: number | null
          created_at?: string
          currency?: string
          deal_id?: string
          expected_profit_minor?: number
          id?: string
          inputs_snapshot?: Json
          market_id?: string
          notes?: string | null
          outcome?: Database["public"]["Enums"]["purchase_outcome"]
          purchased_at?: string
          units?: number
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "purchase_records_deal_currency_fkey"
            columns: ["deal_id", "currency"]
            isOneToOne: false
            referencedRelation: "deals"
            referencedColumns: ["id", "currency"]
          },
          {
            foreignKeyName: "purchase_records_deal_market_fkey"
            columns: ["deal_id", "market_id"]
            isOneToOne: false
            referencedRelation: "deals"
            referencedColumns: ["id", "market_id"]
          },
          {
            foreignKeyName: "purchase_records_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      retailer_products: {
        Row: {
          asin_hint: string | null
          brand: string | null
          created_at: string
          currency: string
          first_seen_at: string
          gtin_format: Database["public"]["Enums"]["gtin_format"] | null
          gtin_raw: string | null
          gtin14: string | null
          id: string
          image_url: string | null
          in_stock: boolean
          last_seen_at: string
          mpn: string | null
          price_minor: number
          price_tax_treatment: Database["public"]["Enums"]["price_tax_treatment"]
          product_url: string | null
          raw: Json | null
          retailer_id: string
          retailer_sku: string
          source_batch_id: string | null
          stock_qty: number | null
          title: string | null
          updated_at: string
          was_price_minor: number | null
        }
        Insert: {
          asin_hint?: string | null
          brand?: string | null
          created_at?: string
          currency: string
          first_seen_at?: string
          gtin_format?: Database["public"]["Enums"]["gtin_format"] | null
          gtin_raw?: string | null
          gtin14?: string | null
          id?: string
          image_url?: string | null
          in_stock?: boolean
          last_seen_at?: string
          mpn?: string | null
          price_minor: number
          price_tax_treatment: Database["public"]["Enums"]["price_tax_treatment"]
          product_url?: string | null
          raw?: Json | null
          retailer_id: string
          retailer_sku: string
          source_batch_id?: string | null
          stock_qty?: number | null
          title?: string | null
          updated_at?: string
          was_price_minor?: number | null
        }
        Update: {
          asin_hint?: string | null
          brand?: string | null
          created_at?: string
          currency?: string
          first_seen_at?: string
          gtin_format?: Database["public"]["Enums"]["gtin_format"] | null
          gtin_raw?: string | null
          gtin14?: string | null
          id?: string
          image_url?: string | null
          in_stock?: boolean
          last_seen_at?: string
          mpn?: string | null
          price_minor?: number
          price_tax_treatment?: Database["public"]["Enums"]["price_tax_treatment"]
          product_url?: string | null
          raw?: Json | null
          retailer_id?: string
          retailer_sku?: string
          source_batch_id?: string | null
          stock_qty?: number | null
          title?: string | null
          updated_at?: string
          was_price_minor?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "retailer_products_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "retailer_products_retailer_id_fkey"
            columns: ["retailer_id"]
            isOneToOne: false
            referencedRelation: "retailers"
            referencedColumns: ["id"]
          },
        ]
      }
      retailers: {
        Row: {
          active: boolean
          affiliate_network: string | null
          affiliate_tracking_template: string | null
          country_code: string
          created_at: string
          currency: string
          id: string
          market_id: string
          name: string
          price_display: Database["public"]["Enums"]["price_tax_treatment"]
          slug: string
          source_type: Database["public"]["Enums"]["retailer_source_type"]
          updated_at: string
          website_url: string | null
        }
        Insert: {
          active?: boolean
          affiliate_network?: string | null
          affiliate_tracking_template?: string | null
          country_code: string
          created_at?: string
          currency: string
          id?: string
          market_id: string
          name: string
          price_display: Database["public"]["Enums"]["price_tax_treatment"]
          slug: string
          source_type: Database["public"]["Enums"]["retailer_source_type"]
          updated_at?: string
          website_url?: string | null
        }
        Update: {
          active?: boolean
          affiliate_network?: string | null
          affiliate_tracking_template?: string | null
          country_code?: string
          created_at?: string
          currency?: string
          id?: string
          market_id?: string
          name?: string
          price_display?: Database["public"]["Enums"]["price_tax_treatment"]
          slug?: string
          source_type?: Database["public"]["Enums"]["retailer_source_type"]
          updated_at?: string
          website_url?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "retailers_country_code_fkey"
            columns: ["country_code"]
            isOneToOne: false
            referencedRelation: "countries"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "retailers_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "retailers_currency_matches_market"
            columns: ["market_id", "currency"]
            isOneToOne: false
            referencedRelation: "markets"
            referencedColumns: ["id", "currency"]
          },
          {
            foreignKeyName: "retailers_market_id_fkey"
            columns: ["market_id"]
            isOneToOne: false
            referencedRelation: "markets"
            referencedColumns: ["id"]
          },
        ]
      }
      tax_schedules: {
        Row: {
          country_code: string
          created_at: string
          effective_from: string
          effective_to: string | null
          id: string
          input_reclaim_supported: boolean
          marketplace_fees_taxed: boolean
          notes: string | null
          reduced_rates: Json
          regime: Database["public"]["Enums"]["tax_regime"]
          registration_supported: boolean
          source_url: string | null
          standard_rate_bps: number
          updated_at: string
          verified_at: string | null
        }
        Insert: {
          country_code: string
          created_at?: string
          effective_from: string
          effective_to?: string | null
          id?: string
          input_reclaim_supported?: boolean
          marketplace_fees_taxed?: boolean
          notes?: string | null
          reduced_rates?: Json
          regime: Database["public"]["Enums"]["tax_regime"]
          registration_supported?: boolean
          source_url?: string | null
          standard_rate_bps: number
          updated_at?: string
          verified_at?: string | null
        }
        Update: {
          country_code?: string
          created_at?: string
          effective_from?: string
          effective_to?: string | null
          id?: string
          input_reclaim_supported?: boolean
          marketplace_fees_taxed?: boolean
          notes?: string | null
          reduced_rates?: Json
          regime?: Database["public"]["Enums"]["tax_regime"]
          registration_supported?: boolean
          source_url?: string | null
          standard_rate_bps?: number
          updated_at?: string
          verified_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "tax_schedules_country_code_fkey"
            columns: ["country_code"]
            isOneToOne: false
            referencedRelation: "countries"
            referencedColumns: ["code"]
          },
        ]
      }
      watchlist_items: {
        Row: {
          created_at: string
          currency: string | null
          deal_id: string
          id: string
          marketplace_product_id: string
          note: string | null
          target_profit_minor: number | null
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          currency?: string | null
          deal_id: string
          id?: string
          marketplace_product_id: string
          note?: string | null
          target_profit_minor?: number | null
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          currency?: string | null
          deal_id?: string
          id?: string
          marketplace_product_id?: string
          note?: string | null
          target_profit_minor?: number | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "watchlist_items_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "watchlist_items_deal_currency_fkey"
            columns: ["deal_id", "currency"]
            isOneToOne: false
            referencedRelation: "deals"
            referencedColumns: ["id", "currency"]
          },
          {
            foreignKeyName: "watchlist_items_deal_product_fkey"
            columns: ["deal_id", "marketplace_product_id"]
            isOneToOne: false
            referencedRelation: "deals"
            referencedColumns: ["id", "marketplace_product_id"]
          },
          {
            foreignKeyName: "watchlist_items_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      [_ in never]: never
    }
    Enums: {
      component_band: "low" | "medium" | "high"
      deal_status: "draft" | "active" | "retired"
      fulfilment_type: "marketplace_fulfilled" | "seller_fulfilled"
      gtin_format: "upc_a" | "ean_13" | "ean_8" | "isbn_13"
      market_launch_status: "live" | "beta" | "planned"
      match_method:
        | "gtin_exact"
        | "retailer_hint"
        | "title_fuzzy"
        | "manual"
        | "barcode_scan"
      match_verified_by: "system" | "admin" | "user_report"
      price_tax_treatment: "inclusive" | "exclusive"
      purchase_outcome: "pending" | "sold" | "partial" | "unsold" | "returned"
      retailer_source_type: "affiliate_feed" | "api" | "curated" | "manual"
      tax_regime: "vat" | "gst" | "sales_tax" | "none"
      tax_scheme: "standard" | "simplified"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      component_band: ["low", "medium", "high"],
      deal_status: ["draft", "active", "retired"],
      fulfilment_type: ["marketplace_fulfilled", "seller_fulfilled"],
      gtin_format: ["upc_a", "ean_13", "ean_8", "isbn_13"],
      market_launch_status: ["live", "beta", "planned"],
      match_method: [
        "gtin_exact",
        "retailer_hint",
        "title_fuzzy",
        "manual",
        "barcode_scan",
      ],
      match_verified_by: ["system", "admin", "user_report"],
      price_tax_treatment: ["inclusive", "exclusive"],
      purchase_outcome: ["pending", "sold", "partial", "unsold", "returned"],
      retailer_source_type: ["affiliate_feed", "api", "curated", "manual"],
      tax_regime: ["vat", "gst", "sales_tax", "none"],
      tax_scheme: ["standard", "simplified"],
    },
  },
} as const
