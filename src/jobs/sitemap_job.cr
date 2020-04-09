require "../../config/config"

class SitemapJob
  def initialize
  end

  def perform
    sitemaps = Sitemapper.build do |builder|
      # builder = itself
      builder.add("/", lastmod: Time.local, priority: 1.0)

      Repository.query.with_user.each do |repository|
        builder.add(repository.decorate.url, lastmod: repository.last_activity_at, priority: 0.8)
      end
    end

    Sitemapper.store(sitemaps, "./public/sitemaps")
  end
end

# job = SitemapJob.new
# job.perform
