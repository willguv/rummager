require "best_bets_checker"
require "elasticsearch/escaping"
require "unf"

# Builds a query for a search across all GOV.UK indices
class UnifiedSearchBuilder
  include Elasticsearch::Escaping

  DEFAULT_QUERY_ANALYZER = "query_default"
  DEFAULT_QUERY_ANALYZER_WITHOUT_SYNONYMS = 'default'
  GOVERNMENT_BOOST_FACTOR = 0.4
  POPULARITY_OFFSET = 0.001

  def initialize(params, metaindex)
    @params = params
    @query = query_normalized
    if @params[:debug][:disable_best_bets]
      @best_bets_checker = BestBetsChecker.new(metaindex, nil)
    else
      @best_bets_checker = BestBetsChecker.new(metaindex, query_normalized)
    end
  end

  def payload
    Hash[{
      from: @params[:start],
      size: @params[:count],
      query: query_hash_with_best_bets,
      filter: filters_hash,
      fields: @params[:return_fields],
      sort: sort_list,
      facets: facets_hash,
      explain: @params[:debug][:explain],
    }.reject{ |key, value|
      [nil, [], {}].include?(value)
    }]
  end

  def query_normalized
    if @params[:query].nil?
      return nil
    end
    # Put the query into NFKC-normal form to ensure that accent handling works
    # correctly in elasticsearch.
    normalizer = UNF::Normalizer.instance
    query = normalizer.normalize(@params[:query], :nfkc).strip
    if query.length == 0
      return nil
    end
    query
  end

  def base_query
    if @query.nil?
      return { match_all: {} }
    end

    if @params[:debug][:disable_popularity]
      boosted_query
    else
      {
        custom_score: {
          query: boosted_query,
          script: "_score * (doc['popularity'].value + #{POPULARITY_OFFSET})"
        }
      }
    end
  end

  def boosted_query
    {
      custom_filters_score: {
        query: {
          bool: {
            should: [core_query]
          }
        },
        filters: boost_filters,
        score_mode: "multiply",
      }
    }
  end

  def boost_filters
    format_boosts + [time_boost] + [closed_org_boost] + [devolved_org_boost]
  end

  def best_bets
    @best_bets_checker.best_bets
  end

  def worst_bets
    @best_bets_checker.worst_bets
  end

  def query_hash_with_best_bets
    bb = best_bets
    wb = worst_bets
    if bb.empty? && wb.empty?
      return query_hash
    end

    bb_max_position = best_bets.keys.max
    bb_queries = bb.map do |position, links|
      {
        custom_boost_factor: {
          query: {
            ids: { values: links },
          },
          boost_factor: (bb_max_position + 1 - position) * 1000000,
        }
      }
    end
    result = {
      bool: {
        should: [query_hash] + bb_queries
      }
    }
    unless wb.empty?
      result[:bool][:must_not] = [ { ids: { values: wb} } ]
    end
    result
  end

  def query_hash
    query = base_query
    {
      indices: {
        indices: [:government],
        query: {
          custom_boost_factor: {
            query: query,
            boost_factor: GOVERNMENT_BOOST_FACTOR
          }
        },
        no_match_query: query
      }
    }
  end

  def combine_filters(filters)
    if filters.length == 0
      nil
    elsif filters.length == 1
      filters.first
    else
      {"and" => filters}
    end
  end

  def filters_hash(excluding=[])
    filter_groups = @params.fetch(:filters).reject { |filter|
      excluding.include?(filter.field_name)
    }.map { |filter|
      filter_hash(filter)
    }

    # exclude any specialist sector documents from the search results, as we
    # currently do not wish to display them
    filter_groups << {
      "not" => {
        "term" => {
          "format" => "specialist_sector"
        }
      }
    }

    # Don't add additional filters to filter_groups without making sure that
    # the facet_filter values used in facets include the filter too.  It's
    # usually better to add additional filters to the query, so that they
    # automatically apply to facet calculation.
    combine_filters(filter_groups)
  end

  def filter_hash(filter)
    case filter.type
    when "string"
      terms_filter(filter)
    when "date"
      date_filter(filter)
    else
      raise "Filter type not supported"
    end
  end

  def terms_filter(filter)
    {"terms" => { filter.field_name => filter.values } }
  end

  def date_filter(filter)
    value = filter.values.first

    {
      "range" => {
        filter.field_name => {
          "from" => value["from"].iso8601,
          "to" => value["to"].iso8601,
        }.reject { |_, v| v.nil? }
      }
    }
  end

  # Get a list of fields being sorted by
  def sort_fields
    order = @params[:order]
    if order.nil?
      return []
    end
    [order[0]]
  end

  # Get a list describing the sort order (or nil)
  def sort_list
    if @params[:order].nil?
      # Sort by popularity when there's no explicit ordering, and there's no
      # query (so there's no relevance scores).
      if @query.nil? && !(@params[:debug][:disable_popularity])
        return [{ "popularity" => { order: "desc" } }]
      else
        return nil
      end
    end

    field, order = @params[:order]

    [{field => {order: order, missing: "_last"}}]
  end

  def facets_hash
    facets = @params[:facets]
    if facets.nil?
      return nil
    end
    result = {}
    facets.each do |field_name, _|
      facet_hash = {
        terms: {
          field: field_name,
          order: "count",
          # We want all the facet values so we can return an accurate count of
          # the number of options.  With elasticsearch 0.90+ we can get this by
          # setting size to 0, but at the time of writing we're using 0.20.6,
          # so just have to set a high value for size.
          size: 100000,
        }
      }
      facet_filter = filters_hash([field_name])
      unless facet_filter.nil?
        facet_hash[:facet_filter] = facet_filter
      end
      result[field_name] = facet_hash
    end
    result
  end

  def core_query
    {
      bool: {
        must: must_conditions,
        should: should_conditions
      }
    }
  end

  def should_conditions
    exact_field_boosts + [ exact_match_boost, shingle_token_filter_boost ]
  end

  def query_analyzer
    if @params[:debug][:disable_synonyms]
      DEFAULT_QUERY_ANALYZER_WITHOUT_SYNONYMS
    else
      DEFAULT_QUERY_ANALYZER
    end
  end

  def exact_field_boosts
    match_fields.map {|field_name, _|
      {
        match_phrase: {
          field_name => {
            query: escape(@query),
            analyzer: query_analyzer,
          }
        }
      }
    }
  end

  def exact_match_boost
    {
      multi_match: {
        query: escape(@query),
        operator: "and",
        fields: match_fields.keys,
        analyzer: query_analyzer
      }
    }
  end

  def shingle_token_filter_boost
    {
      multi_match: {
        query: escape(@query),
        operator: "or",
        fields: match_fields.keys,
        analyzer: "shingled_query_analyzer"
      }
    }
  end

  def query_string_query
    {
      match: {
        _all: {
          query: escape(@query),
          analyzer: query_analyzer,
          minimum_should_match: minimum_should_match
        }
      }
    }
  end

  def minimum_should_match
    # The following specification generates the following values for minimum_should_match
    #
    # Number of | Minimum
    # optional  | should
    # clauses   | match
    # ----------+---------
    # 1         | 1
    # 2         | 2
    # 3         | 2
    # 4         | 3
    # 5         | 3
    # 6         | 3
    # 7         | 3
    # 8+        | 50%
    #
    # This table was worked out by using the comparison feature of
    # bin/search with various example queries of different lengths (3, 4, 5,
    # 7, 9 words) and inspecting the consequences on search results.
    #
    # Reference for the minimum_should_match syntax:
    # http://lucene.apache.org/solr/api-3_6_2/org/apache/solr/util/doc-files/min-should-match.html
    #
    # In summary, a clause of the form "N<M" means when there are MORE than
    # N clauses then M clauses should match. So, 2<2 means when there are
    # MORE than 2 clauses then 2 should match.
    "2<2 3<3 7<50%"
  end

  def must_conditions
    [query_string_query].compact
  end

  def match_fields
    {
      "title" => 5,
      "acronym" => 5, # Ensure that organisations rank brilliantly for their acronym
      "description" => 2,
      "indexable_content" => 1,
    }
  end

  def boosted_formats
    {
      # Mainstream formats
      "smart-answer"      => 1.5,
      "transaction"       => 1.5,
      # Inside Gov formats
      "topical_event"     => 1.5,
      "minister"          => 1.7,
      "organisation"      => 2.5,
      "topic"             => 1.5,
      "document_series"   => 1.3,
      "document_collection" => 1.3,
      "operational_field" => 1.5,
    }
  end

  def format_boosts
    boosted_formats.map do |format, boost|
      {
        filter: { term: { format: format } },
        boost: boost
      }
    end
  end

  # An implementation of http://wiki.apache.org/solr/FunctionQuery#recip
  # Curve for 2 months: http://www.wolframalpha.com/share/clip?f=d41d8cd98f00b204e9800998ecf8427e5qr62u0si
  #
  # Behaves as a freshness boost for newer documents with a public_timestamp and search_format_types announcement
  def time_boost
    {
      filter: { term: { search_format_types: "announcement" } },
      script: "((0.05 / ((3.16*pow(10,-11)) * abs(time() - doc['public_timestamp'].date.getMillis()) + 0.05)) + 0.12)"
    }
  end

  def closed_org_boost
    {
      filter: { term: { organisation_state: "closed" } },
      boost: 0.3,
    }
  end

  def devolved_org_boost
    {
      filter: { term: { organisation_state: "devolved" } },
      boost: 0.3,
    }
  end

end
