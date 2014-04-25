require "timed_cache"

class FacetCountCache
  CACHE_LIFETIME = 12 * 3600  # 12 hours

  def initialize(index, field, clock = Time)
    @index = index
    @field = field
    @cache = TimedCache.new(CACHE_LIFETIME, clock) { fetch }
  end

  def counts
    @cache.get
  end

private
  def fetch
    builder = UnifiedSearchBuilder.new(
      count: 0,
      filters: {},
      facets: { @field => 10_000 },
    )
    es_response = @index.raw_search(builder.payload)

    facet_counts = {}
    es_response["facets"][@field.to_s]["terms"].each { |option|
      count = option["count"]
      if count < 100
        count = 100
      end
      facet_counts[option["term"]] = count
    }

    return facet_counts
  end
end
