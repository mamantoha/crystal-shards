module Helpers
  extend self

  def sync_repository_by_url(url : String) : Repository?
    uri = URI.parse(url)

    if match = uri.path.match(/^\/([\w|-]*)\/([\w|-]*)/)
      user_name = match[1]
      repository_name = match[2]

      case uri.host
      when "github.com"
        github_client = Github::API.new(ENV["GITHUB_USER"], ENV["GITHUB_KEY"])

        if github_repository = github_client.get_repo(user_name, repository_name)
          GithubHelpers.sync_github_repository(github_repository)
        end
      when "gitlab.com"
        gitlab_client = Gitlab::API.new(ENV["GITLAB_ACCESS_TOKEN"])

        if gitlab_project = gitlab_client.project(user_name, repository_name)
          GitlabHelpers.sync_project(gitlab_project)
        end
      end
    end
  end

  def update_dependecies(repository : Repository)
    if shard_yml = repository.shard_yml
      if spec = spec_from_yaml(shard_yml)
        create_relationships(repository, spec.dependencies, false)
        create_relationships(repository, spec.development_dependencies, true)

        remove_outdated_relationships(repository, spec.dependencies, false)
        remove_outdated_relationships(repository, spec.development_dependencies, true)
      end
    end
  end

  def create_relationships(repository : Repository, spec_dependencies : Array(ShardsSpec::Dependency), development : Bool)
    spec_dependencies.each do |spec_dependency|
      if provider_name = (spec_dependency.keys & ["github", "gitlab"]).first?
        if repository_path = spec_dependency[provider_name]
          user_name, repository_name = repository_path.split("/")

          if dependency = Repository.find_repository(user_name, repository_name, provider_name)
            unless Relationship.query.find({master_id: repository.id, dependency_id: dependency.id, development: development})
              Relationship.create!({
                master_id:     repository.id,
                dependency_id: dependency.id,
                development:   development,
                branch:        spec_dependency.refs,
                version:       spec_dependency.version,
              })
            end
          end
        end
      end
    end
  end

  def remove_outdated_relationships(repository : Repository, spec_dependencies : Array(ShardsSpec::Dependency), development : Bool)
    dependencies = repository.dependencies.where { relationships.development == development }

    dependencies.each do |dependency|
      repository_path = [dependency.user.login, dependency.name].join('/').downcase

      if spec_dependencies.none? { |dep| dep.fetch(dependency.provider, "").downcase == repository_path }
        if relationship = Relationship.query.where({master_id: repository.id, dependency_id: dependency.id, development: development}).first
          relationship.delete
        end
      end
    end
  end

  def spec_from_yaml(s)
    ShardsSpec::Spec.from_yaml(s)
  rescue
    nil
  end

  def to_markdown(content : String, repository_url) : String
    options = Cmark::Option.flags(Unsafe, Nobreaks, ValidateUTF8)
    extensions = Cmark::Extension.flags(Table, Strikethrough, Autolink, Tagfilter, Tasklist)

    node = Cmark.parse_gfm(content, options)
    renderer = ReadmeRenderer.new(options, extensions, repository_url)

    renderer.render(node)
  end
end
