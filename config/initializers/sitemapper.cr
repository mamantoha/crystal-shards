require "sitemapper"
require "../../src/ext/sitemapper"

Sitemapper.configure do |c|
  # Generate a sitemap_index file
  c.use_index = true # default false

  c.host = "https://shards.info"

  c.sitemap_host = "https://shards.info" # default nil

  # The max number of <url> elements to add to each sitemap
  c.max_urls = 500 # default 500

  # use gzip compression?
  c.compress = true # default true

  # where to store the sitemaps
  c.storage = :local # :aws || :local

  # see the aws config stuff below
  c.aws_config = nil # default is nil but should be a Hash(String, String) when used
end
