#!/usr/bin/env ruby
# frozen_string_literal: true

require "English"
require "fileutils"
require "find"
require "open3"
# Required when this script runs outside the Homebrew style environment.
# rubocop:disable Lint/RedundantRequireStatement
require "pathname"
# rubocop:enable Lint/RedundantRequireStatement
require "yaml"

# This makes sense for a standalone script.
# rubocop:disable Style/TopLevelMethodDefinition
def git(*args)
  system "git", *args
  exit $CHILD_STATUS.exitstatus unless $CHILD_STATUS.success?
end
# rubocop:enable Style/TopLevelMethodDefinition

if ARGV[0].to_s.empty? || ARGV[1].to_s.empty? || ARGV[3]
  abort "Usage: #{$PROGRAM_NAME} <target_directory_path> <homebrew_repository_path> [brewsh_repository_path]"
end

target_directory = ARGV.fetch(0)
target_directory_path = Pathname(target_directory).expand_path
repository_name = target_directory_path.basename.to_s
homebrew_repository_path = Pathname(ARGV.fetch(1)).expand_path

brewsh_repository = ARGV.fetch(2, "")
brewsh_repository_path = Pathname(brewsh_repository).expand_path unless brewsh_repository.empty?

if !target_directory_path.directory? || !homebrew_repository_path.directory?
  abort "Usage: #{$PROGRAM_NAME} <target_directory_path> <homebrew_repository_path> [brewsh_repository_path]"
end
abort "#{brewsh_repository_path} is not a directory" if brewsh_repository_path && !brewsh_repository_path.directory?

docs = "docs"
ruby_version = ".ruby-version"
rubocop_yaml = ".rubocop.yml"
vale_ini = ".vale.ini"
dependabot_template_yaml = ".github/actions/sync/dependabot.template.yml"
dependabot_yaml = ".github/dependabot.yml"
check_template_rb = ".github/scripts/check_template.rb"
docs_workflow_yaml = ".github/workflows/docs.yml"
actionlint_workflow_yaml = ".github/workflows/actionlint.yml"
check_issues_workflow_yaml = ".github/workflows/check-issues.yml"
check_prs_workflow_yaml = ".github/workflows/check-prs.yml"
check_workflow_yamls = [
  check_issues_workflow_yaml,
  check_prs_workflow_yaml,
].freeze
stale_issues_workflow_yaml = ".github/workflows/stale-issues.yml"
zizmor_yml = ".github/zizmor.yml"
codeql_extensions_homebrew_actions_yml = ".github/codeql/extensions/homebrew-actions.yml"
brewsh_assets_url = "https://brew.sh"

homebrew_docs = homebrew_repository_path/docs
homebrew_ruby_version =
  (homebrew_repository_path/"Library/Homebrew/vendor/portable-ruby-version").read
  .chomp
  .sub(/_\d+$/, "")
homebrew_gemfile = (homebrew_repository_path/"Library/Homebrew/Gemfile")
homebrew_gemfile_lock = (homebrew_repository_path/"Library/Homebrew/Gemfile.lock")
homebrew_rubocop_config_yaml = YAML.load_file(
  homebrew_repository_path/"Library/#{rubocop_yaml}",
  permitted_classes: [Symbol, Regexp],
)
homebrew_rubocop_config_yaml["AllCops"]["Exclude"] << "**/vendor/**/*"
homebrew_rubocop_config = homebrew_rubocop_config_yaml.reject do |key, _|
  key.match?(%r{\Arequire|plugins|inherit_from|inherit_mode|Cask/|Formula|Homebrew|Performance/|RSpec|Sorbet/})
end.to_yaml
homebrew_docs_rubocop_config_yaml = YAML.load_file(
  homebrew_repository_path/"docs/#{rubocop_yaml}",
  permitted_classes: [Symbol, Regexp],
)
homebrew_docs_rubocop_config = homebrew_docs_rubocop_config_yaml.reject do |key, _|
  key.match?(%r{\AFormulaAudit/|Sorbet/})
end.to_yaml
   .sub('inherit_from: "../Library/.rubocop.yml"', 'inherit_from: "../.rubocop.yml"')
homebrew_docs_workflow_yaml = homebrew_repository_path/docs_workflow_yaml
homebrew_vale_ini = homebrew_repository_path/vale_ini

target_gemfile_locks = []
dependabot_config_yaml = YAML.load_file(dependabot_template_yaml)
# This should be run after dependabot.yml for this repository (Monday)
# and after the sync-shared-config job for synced repositories (Wednesday).
# This maximises the chance of a single sync per week handling both any
# changes and any dependabot updates.
dependabot_config_yaml["updates"].each do |update|
  update["schedule"]["day"] = "friday" if update["schedule"]
end
dependabot_config_yaml["updates"] = dependabot_config_yaml["updates"].filter_map do |update|
  bundler_ecosystem = false
  package_ecosystem = update["package-ecosystem"]
  ecosystem_file = case package_ecosystem
  when "bundler"
    bundler_ecosystem = true
    "Gemfile.lock"
  when "cargo"
    "Cargo.toml"
  when "devcontainers"
    ".devcontainer/devcontainer.json"
  when "docker"
    "Dockerfile"
  when "npm"
    "package.json"
  when "pip"
    "requirements.txt"
  when "opentofu"
    ".terraform.lock.hcl"
  end

  keep_update = if (update_directories = update["directories"])
    update_directories.select! do |directory|
      next package_ecosystem == "github-actions" && repository_name == "actions" if directory == "/*"

      ecosystem_file_path = (target_directory_path/".#{directory}/#{ecosystem_file}")
      next unless ecosystem_file_path.exist?

      target_gemfile_locks << ecosystem_file_path if bundler_ecosystem

      true
    end
    update["directories"] = update_directories
    update_directories.any?
  elsif (update_directory = update.fetch("directory"))
    (target_directory_path/".#{update_directory}/#{ecosystem_file}").exist?
  else
    true
  end
  next unless keep_update

  update
end
dependabot_config = dependabot_config_yaml.to_yaml

custom_ruby_version_repos = %w[
  patchelf.rb
  ruby-macho
].freeze
custom_rubocop_repos = %w[
  ci-orchestrator-private
  patchelf.rb
  ruby-macho
].freeze
template_check_repositories = %w[
  brew
  homebrew-core
  homebrew-cask
].freeze
rejected_docs_basenames = %w[
  _config.yml
  CNAME
  index.md
  README.md
].freeze

deprecated_lock_threads = ".github/workflows/lock-threads.yml"

puts "Detecting changes…"
[
  docs,
  docs_workflow_yaml,
  vale_ini,
  ruby_version,
  rubocop_yaml,
  dependabot_yaml,
  check_template_rb,
  deprecated_lock_threads,
  actionlint_workflow_yaml,
  *check_workflow_yamls,
  stale_issues_workflow_yaml,
  zizmor_yml,
  codeql_extensions_homebrew_actions_yml,
].each do |path|
  target_path = target_directory_path/path
  target_path.dirname.mkpath

  case path
  when docs
    # The docs templates are from the `brew` repository so we don't want to "sync" them.
    next if repository_name == "brew"

    next if path == target_path.to_s
    next unless target_path.exist?
    next unless target_path.directory?

    Find.find(homebrew_docs.to_s) do |docs_path|
      docs_path = Pathname(docs_path)
      docs_path_basename = docs_path.basename.to_s
      next Find.prune if docs_path_basename == "vendor"
      next if docs_path.directory?
      next if rejected_docs_basenames.include?(docs_path_basename)

      docs_path_subpath = docs_path.to_s.delete_prefix("#{homebrew_docs}/")
      next if docs_path_subpath.start_with?("_includes/", "_layouts/", "_sass/", "assets/css/", "bin/jekyll")
      next if docs_path_subpath.start_with?("assets/img/") && !docs_path_subpath.start_with?("assets/img/docs/")

      target_docs_path = target_path/docs_path_subpath
      next if docs_path.extname == ".png"
      next if docs_path.extname == ".md" && !target_docs_path.exist?
      next if target_docs_path.to_s.include?("vendor")

      target_docs_path.dirname.mkpath

      if [ruby_version, "Gemfile"].include?(docs_path_basename) &&
         (target_path/docs_path_basename).exist?
        FileUtils.rm target_docs_path
        Dir.chdir target_path do
          FileUtils.ln_s "../#{docs_path_basename}", "."
        end
      elsif docs_path_basename == ".rubocop.yml"
        FileUtils.rm_f target_docs_path
        target_docs_path.write(
          "# This file is synced from `Homebrew/brew` by the `.github` repository, do not modify it directly.\n" \
          "#{homebrew_docs_rubocop_config}\n",
        )
      elsif docs_path != target_docs_path
        FileUtils.cp docs_path, target_docs_path
      end
    end
  when docs_workflow_yaml, vale_ini
    # The docs templates are from the `brew` repository so we don't want to "sync" them.
    next if repository_name == "brew"

    docs_path = target_directory_path/docs
    next unless docs_path.exist?
    next unless docs_path.directory?

    path = case path
    when docs_workflow_yaml then homebrew_docs_workflow_yaml
    when vale_ini           then homebrew_vale_ini
    else raise "Unexpected path: #{path}"
    end
    next if path == target_path.to_s

    contents = path.read
    FileUtils.rm_f target_path
    target_path.write(
      "# This file is synced from `Homebrew/brew` by the `.github` repository, do not modify it directly.\n" \
      "#{contents}\n",
    )
  when ruby_version
    next if custom_ruby_version_repos.include?(repository_name)

    target_path = target_directory_path/"Library/Homebrew/#{ruby_version}" if repository_name == "brew"

    if target_path.exist?
      target_ruby_version = target_path.read.chomp

      # Don't downgrade the Ruby version even if Portable Ruby was downgraded.
      next if Gem::Version.new(homebrew_ruby_version) < Gem::Version.new(target_ruby_version)
    end

    target_path.write("#{homebrew_ruby_version}\n")
  when rubocop_yaml
    next if custom_rubocop_repos.include?(repository_name)

    FileUtils.rm_f target_path
    target_path.write(
      "# This file is synced from `Homebrew/brew` by the `.github` repository, do not modify it directly.\n" \
      "#{homebrew_rubocop_config}\n",
    )
  when dependabot_yaml, actionlint_workflow_yaml, check_issues_workflow_yaml, check_prs_workflow_yaml,
       stale_issues_workflow_yaml,
       zizmor_yml, codeql_extensions_homebrew_actions_yml
    contents = if path == dependabot_yaml
      dependabot_config
    else
      next if path == target_path.to_s

      # ensure we don't replace the non-dependabot template files in this repository
      next if repository_name == ".github"

      if check_workflow_yamls.include?(path) && template_check_repositories.none?(repository_name)
        FileUtils.rm_f target_path
        next
      end

      Pathname(path).read
                    .chomp
    end

    FileUtils.rm_f target_path
    target_path.write(
      "# This file is synced from the `.github` repository, do not modify it directly.\n" \
      "#{contents}\n",
    )
  when check_template_rb
    next if path == target_path.to_s

    if template_check_repositories.none?(repository_name)
      FileUtils.rm_f target_path
      next
    end

    FileUtils.cp path, target_path
  when deprecated_lock_threads
    next unless target_path.exist?

    git "-C", target_directory, "rm", path
  else
    next if path == target_path.to_s

    FileUtils.cp path, target_path
  end
end

if brewsh_repository_path && repository_name != "brew.sh"
  theme_site_path = case repository_name
  when "formulae.brew.sh"
    target_directory_path
  else
    target_docs_path = target_directory_path/docs
    target_docs_path if target_docs_path.directory?
  end

  if theme_site_path
    shared_theme_paths = %w[_includes _layouts].flat_map do |theme_path|
      source_path = brewsh_repository_path/theme_path
      next [] unless source_path.directory?

      Find.find(source_path.to_s).filter_map do |path|
        path = Pathname(path)
        next if path.directory?

        path.to_s.delete_prefix("#{brewsh_repository_path}/")
      end
    end

    bin_jekyll = "bin/jekyll"
    shared_theme_paths << bin_jekyll if (brewsh_repository_path/bin_jekyll).file?

    read_front_matter = lambda do |path|
      next {} unless path.file?

      contents = path.read
      front_matter = contents.match(/\A---\s*\n(.*?)\n---\s*\n/m)
      next {} unless front_matter

      YAML.safe_load(front_matter[1], permitted_classes: [Symbol], aliases: true) || {}
    rescue Psych::Exception
      {}
    end

    layout_path = lambda do |site_path, layout_name|
      %w[html json md markdown].filter_map do |extension|
        path = site_path/"_layouts/#{layout_name}.#{extension}"
        path if path.file?
      end.first
    end

    required_layouts = []
    config_yml = theme_site_path/"_config.yml"
    if config_yml.file?
      config = YAML.safe_load(config_yml.read, permitted_classes: [Symbol], aliases: true) || {}
      Array(config["defaults"]).each do |default|
        required_layouts << default.dig("values", "layout")
      end
    end
    has_posts = (theme_site_path/"_posts").directory?

    Find.find(theme_site_path.to_s) do |path|
      path = Pathname(path)
      relative_path = path.to_s.delete_prefix("#{theme_site_path}/")
      if path.directory?
        next Find.prune if %w[.git .jekyll-cache _site assets vendor].include?(path.basename.to_s)
        next Find.prune if relative_path.start_with?("_includes", "_layouts", "bin")

        next
      end
      next unless %w[.html .md .markdown].include?(path.extname)

      required_layouts << read_front_matter.call(path)["layout"]
    end

    theme_paths = [bin_jekyll]
    seen_layouts = []
    until required_layouts.empty?
      layout = required_layouts.shift
      next if layout.to_s.empty? || seen_layouts.include?(layout)

      seen_layouts << layout
      source_layout_path = layout_path.call(brewsh_repository_path, layout)
      target_layout_path = layout_path.call(theme_site_path, layout)

      if source_layout_path
        theme_paths << source_layout_path.to_s.delete_prefix("#{brewsh_repository_path}/")
        required_layouts << read_front_matter.call(source_layout_path)["layout"]
      elsif target_layout_path
        required_layouts << read_front_matter.call(target_layout_path)["layout"]
      end
    end

    required_includes = theme_paths.filter_map do |theme_path|
      next unless theme_path.start_with?("_layouts/")

      (brewsh_repository_path/theme_path).read.scan(/{%-?\s*include\s+([^"'\s%]+|"[^"]+"|'[^']+')/).flatten
    end.flatten

    until required_includes.empty?
      include_path = required_includes.shift
      include_path = include_path.delete_prefix("'").delete_prefix('"').delete_suffix("'").delete_suffix('"')
      next if include_path == "feed.html" && !has_posts

      theme_path = "_includes/#{include_path}"
      # `exclude?` is not available in all Ruby contexts this script may run in.
      # rubocop:disable Homebrew/NegateInclude
      next if theme_paths.include?(theme_path) || !shared_theme_paths.include?(theme_path)
      # rubocop:enable Homebrew/NegateInclude

      theme_paths << theme_path
      required_includes.concat(
        (brewsh_repository_path/theme_path).read.scan(/{%-?\s*include\s+([^"'\s%]+|"[^"]+"|'[^']+')/).flatten,
      )
    end

    source_assets = theme_paths.filter_map do |theme_path|
      source_path = brewsh_repository_path/theme_path
      next unless source_path.file?

      source_path.read.scan(%r{"/assets/([^/]+)/}).flatten
    end.flatten.uniq

    source_assets.each do |asset_type|
      target_path = theme_site_path/"assets/#{asset_type}"
      if asset_type == "img"
        next unless target_path.directory?

        target_path.children.select(&:file?).each { |child| FileUtils.rm_f child }
        target_path.rmdir if target_path.children.empty?
      else
        FileUtils.rm_rf target_path
      end
    end

    (shared_theme_paths - theme_paths).each do |theme_path|
      FileUtils.rm_f theme_site_path/theme_path
    end

    theme_paths.each do |theme_path|
      source_path = brewsh_repository_path/theme_path
      next unless source_path.exist?

      if source_path.directory?
        Find.find(source_path.to_s) do |path|
          path = Pathname(path)
          next if path.directory?

          relative_path = path.to_s.delete_prefix("#{source_path}/")
          target_path = theme_site_path/theme_path/relative_path
          next if path == target_path

          target_path.dirname.mkpath
          FileUtils.cp path, target_path
          FileUtils.chmod path.stat.mode, target_path
        end
      else
        target_path = theme_site_path/theme_path
        next if source_path == target_path

        target_path.dirname.mkpath
        FileUtils.cp source_path, target_path
        FileUtils.chmod source_path.stat.mode, target_path
      end
    end

    %w[_includes _layouts].each do |theme_path|
      target_path = theme_site_path/theme_path
      next unless target_path.directory?

      Find.find(target_path.to_s) do |path|
        path = Pathname(path)
        next if path.directory?

        contents = path.read
        updated_contents = contents.gsub(%r{\{\{\s*"/assets/(css|img)/([^"]+)"\s*\|\s*relative_url\s*\}\}}) do
          "#{brewsh_assets_url}/assets/#{Regexp.last_match(1)}/#{Regexp.last_match(2)}"
        end
        unless has_posts
          updated_contents = updated_contents
                             .gsub("form-action 'self' https://buttondown.email;", "form-action 'self';")
                             .gsub("The `jekyll-feed` and `jekyll-seo-tag` plugins use",
                                   "The `jekyll-seo-tag` plugin uses")
                             .gsub("control this behavior in the plugins,", "control this behavior in the plugin,")
          updated_contents = updated_contents.gsub(
            /
              \n\s*\{%\s*if\s+site\.feed\s+and\s+site\.posts\.size\s*>\s*0\s*-?%\}
              \n\s*\{%\s*include\s+feed\.html\s*-?%\}
              \n\s*\{%\s*endif\s*-?%\}
            /x,
            "",
          )
        end
        path.write updated_contents if contents != updated_contents
      end
    end

    Find.find(theme_site_path.to_s) do |path|
      path = Pathname(path)
      relative_path = path.to_s.delete_prefix("#{theme_site_path}/")
      if path.directory?
        next Find.prune if %w[.git .jekyll-cache _site vendor].include?(path.basename.to_s)
        next Find.prune if relative_path.start_with?("assets")

        next
      end
      next unless [".html", ".md", ".markdown", ".yml", ".yaml"].include?(path.extname)

      contents = path.read
      updated_contents = contents.gsub(%r{(:\s*["']?)/assets/img/([^/"'\s]+)(["']?)}) do
        "#{Regexp.last_match(1)}#{brewsh_assets_url}/assets/img/#{Regexp.last_match(2)}#{Regexp.last_match(3)}"
      end
      path.write updated_contents if contents != updated_contents
    end
  end
end

# Update Gemfile.lock if it exists, based on the Ruby version.
#
# We don't need to sync non-docs Gemfiles in Homebrew/brew because they are the source of truth.
unless custom_ruby_version_repos.include?(repository_name)
  target_gemfile_locks.each do |target_gemfile_lock|
    is_docs_lock = target_gemfile_lock.dirname.basename.to_s == docs

    # Skip non-docs Gemfile.lock for brew since it's the source of truth.
    next if repository_name == "brew" && !is_docs_lock

    target_directory_path = target_gemfile_lock.dirname
    Dir.chdir target_directory_path do
      require "bundler"
      bundler_version = Bundler::Definition.build(
        homebrew_gemfile,
        homebrew_gemfile_lock,
        false,
      ).locked_gems.bundler_version
      puts "Running bundle update (with Bundler #{bundler_version})..."
      system "bundle", "update", "--ruby", "--bundler=#{bundler_version}", "--quiet", out: "/dev/null"
    end
  end
end

out, err, status = Open3.capture3("git", "-C", target_directory, "status", "--porcelain", "--ignore-submodules=dirty")
raise err unless status.success?

target_directory_path_changed = !out.chomp.empty?

unless target_directory_path_changed
  puts "No changes detected."
  exit
end

git "-C", target_directory, "add", "--all"

out, err, status = Open3.capture3("git", "-C", target_directory, "diff", "--name-only", "--staged")
raise err unless status.success?

modified_paths = out.lines.map(&:chomp)

modified_paths.each do |modified_path|
  puts "Detected changes to #{modified_path}."
  git "-C", target_directory, "commit", modified_path, "--message",
      "#{File.basename(modified_path)}: update to match main configuration", "--quiet"
end
puts

if ENV["GITHUB_ACTIONS"]
  File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |f|
    f.puts "pull_request=true"
  end
end
