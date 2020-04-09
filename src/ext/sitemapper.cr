# TODO remove this when https://github.com/jwoertink/sitemapper/pull/12 will be merged
module Sitemapper
  def self.build
    builder = Sitemapper::Builder.new(config.host, config.max_urls, config.use_index)
    with builder yield builder
    builder.generate
  end

  def self.build(host : String, max_urls : Int32, use_index : Bool)
    builder = Sitemapper::Builder.new(host, max_urls, use_index)
    with builder yield builder
    builder.generate
  end
end
