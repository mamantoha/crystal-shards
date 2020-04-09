require "dotenv"
Dotenv.load?

require "shards/spec"
require "yaml"
require "base64"
require "kemal"
require "kilt/slang"
require "crest"
require "emoji"
require "humanize_time"
require "autolink"
require "raven"
require "raven/integrations/kemal"

require "../config/config"
require "./config"
require "./view_helpers"

require "./lib/cmark/readme_renderer"

Raven.configure do |config|
  config.async = true
  config.environments = %w(production)
  config.current_environment = ENV.fetch("KEMAL_ENV", "development")
  config.connect_timeout = 5.seconds
  config.read_timeout = 5.seconds
end

Kemal.config.add_handler(Raven::Kemal::ExceptionHandler.new)

static_headers do |response, filepath, filestat|
  duration = 1.day.total_seconds.to_i
  response.headers.add "Cache-Control", "public, max-age=#{duration}"
end

before_all do |env|
  # Redirect from old `/repos` URLs to `/github`
  if env.request.resource.starts_with?("/repos")
    new_resourse = env.request.resource.sub(%r{\A/(repos)}, "/github")
    env.redirect(new_resourse, 301)
  end
end

before_all do |env|
  Config.config.open_graph = OpenGraph.new
  Config.config.open_graph.url = "https://shards.info#{env.request.path}"
  Config.config.query = env.request.query_params["query"]?.to_s
end

error 404 do
  render "src/views/404.slang"
end

get "/" do |env|
  trending_repositories =
    Repository
      .query
      .with_user
      .with_tags
      .where { last_activity_at > 1.week.ago }
      .order_by(stars_count: :desc)
      .limit(20)

  recently_repositories =
    Repository
      .query
      .with_user
      .with_tags
      .order_by(last_activity_at: :desc)
      .limit(20)

  Config.config.page_title = "shards.info"
  Config.config.page_description = "See what the Crystal community is most excited about today"
  Config.config.current_page = "home"

  render "src/views/index.slang", "src/views/layouts/layout.slang"
end

get "/users" do |env|
  page = env.params.query["page"]? || ""
  page = page.to_i? || 1
  per_page = 30
  offset = (page - 1) * per_page

  users_query =
    User
      .query
      .join("repositories") { var("repositories", "user_id") == var("users", "id") }
      .select(
        "users.*",
        "SUM(repositories.stars_count) AS stars_count",
        "COUNT(repositories.*) AS repositories_count",
      )
      .group_by("users.id")
      .order_by(stars_count: :desc)

  total_count = users_query.count

  paginator = ViewHelpers::Paginator.new(page, per_page, total_count, "/users?page=%{page}").to_s

  users = users_query.limit(per_page).offset(offset)

  Config.config.page_title = "Crystal developers"
  Config.config.page_description = "Crystal developers"
  Config.config.current_page = "users"

  render "src/views/users/index.slang", "src/views/layouts/layout.slang"
end

get "/tags" do |env|
  skipped_tags = [
    "crystal", "crystal-language", "crystallang", "crystal-lang", "crystal-shard", "crystal-shards",
    "shard", "shards",
  ]

  tags_json = CACHE.fetch("tags_json") do
    tags =
      Tag
        .query
        .where { ~(name.in? skipped_tags) }
        .join("repository_tags") { repository_tags.tag_id == var("tags", "id") }
        .group_by("tags.id")
        .order_by(tagging_count: :desc)
        .limit(200)
        .select(
          "tags.*",
          "COUNT(repository_tags.*) AS tagging_count"
        )

    tags_array = [] of Hash(String, String)

    tags.each(fetch_columns: true) do |tag|
      tags_array << {
        "text"   => tag.name.to_s,
        "weight" => tag.attributes["tagging_count"].to_s,
        "link"   => "/tags/#{tag.name}",
      }
    end

    tags_array.to_json
  end

  Config.config.page_title = "Tags on shards.info"
  Config.config.page_description = "Browse popular tags on shards.info"
  Config.config.current_page = "tags"

  render "src/views/tags/index.slang", "src/views/layouts/layout.slang"
end

get "/search" do |env|
  if env.params.query.[]?("query").nil? || env.params.query.[]?("query").try(&.empty?)
    env.redirect "/"
  else
    page = env.params.query["page"]? || ""
    page = page.to_i? || 1
    per_page = 20
    offset = (page - 1) * per_page

    query = env.params.query["query"].as(String)

    repositories_query =
      Repository
        .query
        .with_tags
        .with_user
        .search(query)
        .order_by(stars_count: :desc)

    total_count = repositories_query.count

    paginator = ViewHelpers::Paginator.new(
      page,
      per_page,
      total_count,
      "/search?query=#{query}&page=%{page}"
    ).to_s

    repositories = repositories_query.limit(per_page).offset(offset)

    Config.config.page_title = "Search for '#{query}'"
    Config.config.page_description = "Search Crystal repositories for '#{query}'"

    render "src/views/search/index.slang", "src/views/layouts/layout.slang"
  end
end

get "/repos/:owner" { }
get "/:provider/:owner" do |env|
  provider = env.params.url["provider"]
  owner = env.params.url["owner"]

  if user = User.query.with_repositories(&.with_tags).find({provider: provider, login: owner})
    repositories = user.repositories.with_user.with_tags.order_by(stars_count: :desc)
    repositories_count = repositories.count

    Config.config.page_title = "#{user.login} Crystal repositories"
    Config.config.page_description = "#{user.login} has #{repositories_count} Crystal repositories"

    Config.config.open_graph.title = "#{user.login} (#{user.name})"
    Config.config.open_graph.description = "#{user.login} has #{repositories_count} Crystal repositories"
    Config.config.open_graph.image = "#{user.decorate.avatar}"
    Config.config.open_graph.type = "profile"

    render "src/views/users/show.slang", "src/views/layouts/layout.slang"
  else
    raise Kemal::Exceptions::RouteNotFound.new(env)
  end
end

get "/repos/:owner/:repo" { }
get "/:provider/:owner/:repo" do |env|
  provider = env.params.url["provider"]
  owner = env.params.url["owner"]
  repo = env.params.url["repo"]

  if repository = Repository.find_repository(owner, repo, provider)
    dependents =
      repository
        .dependents
        .undistinct
        .order_by({stars_count: :desc})

    dependents_count = dependents.count

    readme_html =
      if repository_readme = repository.readme
        Helpers.to_markdown(repository_readme, repository.decorate.provider_url)
      else
        ""
      end

    Config.config.page_title = "#{repository.decorate.full_name}: #{repository.decorate.description_with_emoji}"
    Config.config.page_description = "#{repository.decorate.full_name}: #{repository.decorate.description_with_emoji}"
    Config.config.open_graph.title = "#{repository.decorate.full_name}"
    Config.config.open_graph.description = "#{repository.decorate.description_with_emoji}"
    Config.config.open_graph.image = "#{repository.user.avatar_url}"

    render "src/views/repositories/show.slang", "src/views/layouts/layout.slang"
  else
    raise Kemal::Exceptions::RouteNotFound.new(env)
  end
end

get "/repos/:owner/:repo/dependents" { }
get "/:provider/:owner/:repo/dependents" do |env|
  provider = env.params.url["provider"]
  owner = env.params.url["owner"]
  repo = env.params.url["repo"]

  page = env.params.query["page"]? || ""
  page = page.to_i? || 1
  per_page = 20
  offset = (page - 1) * per_page

  if repository = Repository.find_repository(owner, repo, provider)
    # TODO: Exception:  (Clear::SQL::RecordNotFoundError)
    # when calling with `.with_user` and limit/offset
    repositories_query =
      repository
        .dependents
        .undistinct
        .order_by({stars_count: :desc})

    total_count = repositories_query.count

    paginator = ViewHelpers::Paginator.new(
      page,
      per_page,
      total_count,
      "/#{provider}/#{owner}/#{repo}/dependents?page=%{page}"
    ).to_s

    repositories = repositories_query.limit(per_page).offset(offset)

    Config.config.page_title = "Depend on '#{repository.decorate.full_name}'"
    Config.config.page_description = "Depend on '#{repository.decorate.full_name}'"

    render "src/views/dependents/index.slang", "src/views/layouts/layout.slang"
  else
    raise Kemal::Exceptions::RouteNotFound.new(env)
  end
end

get "/tags/:name" do |env|
  page = env.params.query["page"]? || ""
  page = page.to_i? || 1
  per_page = 20
  offset = (page - 1) * per_page

  name = env.params.url["name"]

  if tag = Tag.query.find({name: name})
    repositories_query = tag.repositories

    total_count = repositories_query.count

    paginator = ViewHelpers::Paginator.new(
      page,
      per_page,
      total_count,
      "/tags/#{name}?page=%{page}"
    ).to_s

    repositories =
      repositories_query
        .undistinct
        .with_tags
        .with_user
        .order_by(stars_count: :desc)
        .limit(per_page)
        .offset(offset)

    Config.config.page_title = "Repositories tagged with '#{name}'"
    Config.config.page_description = "Crystal repositories with tag '#{name}'"

    render "src/views/tags/show.slang", "src/views/layouts/layout.slang"
  else
    raise Kemal::Exceptions::RouteNotFound.new(env)
  end
end

Kemal.run
