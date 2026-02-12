#!/usr/bin/env ruby
# frozen_string_literal: true

require "English"
require "fileutils"
require "open3"
require "pathname"
require "yaml"

# This makes sense for a standalone script.
# rubocop:disable Style/TopLevelMethodDefinition
def git(*args)
  system "git", *args
  exit $CHILD_STATUS.exitstatus unless $CHILD_STATUS.success?
end
# rubocop:enable Style/TopLevelMethodDefinition

target_directory = ARGV.fetch(0, "")
target_directory_path = Pathname(target_directory)
repository_name = target_directory_path.basename.to_s
homebrew_repository_path = Pathname(ARGV.fetch(1, ""))

if !target_directory_path.directory? || !homebrew_repository_path.directory? || ARGV[2]
  abort "Usage: #{$PROGRAM_NAME} <target_directory_path> <homebrew_repository_path>"
end

docs = "docs"
ruby_version = ".ruby-version"
rubocop_yaml = ".rubocop.yml"
vale_ini = ".vale.ini"
dependabot_template_yaml = ".github/actions/sync/dependabot.template.yml"
dependabot_yaml = ".github/dependabot.yml"
docs_workflow_yaml = ".github/workflows/docs.yml"
actionlint_workflow_yaml = ".github/workflows/actionlint.yml"
stale_issues_workflow_yaml = ".github/workflows/stale-issues.yml"
zizmor_yml = ".github/zizmor.yml"
codeql_extensions_homebrew_actions_yml = ".github/codeql/extensions/homebrew-actions.yml"

homebrew_docs = homebrew_repository_path/docs
homebrew_ruby_version =
  (homebrew_repository_path/"Library/Homebrew/vendor/portable-ruby-version").read
                                                                            .chomp
                                                                            .sub(/_\d+$/, "")
homebrew_gemfile = (homebrew_repository_path/"Library/Homebrew/Gemfile")
homebrew_gemfile_lock = (homebrew_repository_path/"Library/Homebrew/Gemfile.lock")
homebrew_docs_gemfile = (homebrew_repository_path/"docs/Gemfile")
homebrew_docs_gemfile_lock = (homebrew_repository_path/"docs/Gemfile.lock")
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
  ecosystem_file = case update["package-ecosystem"]
  when "bundler"
    bundler_ecosystem = true
    "Gemfile.lock"
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

  keep_update = if ecosystem_file && (update_directories = update["directories"])
    update_directories.select! do |directory|
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
  ruby-macho
].freeze
custom_rubocop_repos = %w[
  ci-orchestrator-private
  ruby-macho
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
  deprecated_lock_threads,
  actionlint_workflow_yaml,
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

    homebrew_docs.find do |docs_path|
      docs_path_basename = docs_path.basename.to_s
      next Find.prune if docs_path_basename == "vendor"
      next if docs_path.directory?
      next if rejected_docs_basenames.include?(docs_path_basename)

      docs_path_subpath = docs_path.to_s.delete_prefix("#{homebrew_docs}/")
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
  when dependabot_yaml, actionlint_workflow_yaml, stale_issues_workflow_yaml,
       zizmor_yml, codeql_extensions_homebrew_actions_yml
    contents = if path == dependabot_yaml
      dependabot_config
    else
      next if path == target_path.to_s

      # ensure we don't replace the non-dependabot template files in this repository
      next if repository_name == ".github"

      Pathname(path).read
                    .chomp
    end

    FileUtils.rm_f target_path
    target_path.write(
      "# This file is synced from the `.github` repository, do not modify it directly.\n" \
      "#{contents}\n",
    )
  when deprecated_lock_threads
    next unless target_path.exist?

    git "-C", target_directory, "rm", path
  else
    next if path == target_path.to_s

    FileUtils.cp path, target_path
  end
end

# Update Gemfile.lock if it exists, based on the Ruby version.
#
# We don't need to sync Gemfiles in Homebrew/brew because they are the source of truth.
# We don't have Homebrew exclude? method here.
# rubocop:disable Homebrew/NegateInclude
if !custom_ruby_version_repos.include?(repository_name) && repository_name != "brew"
  target_gemfile_locks.each do |target_gemfile_lock|
    target_directory_path = target_gemfile_lock.dirname
    Dir.chdir target_directory_path do
      require "bundler"
      is_docs_lock = target_gemfile_lock.dirname.basename.to_s == docs
      bundler_version = Bundler::Definition.build(
        is_docs_lock ? homebrew_docs_gemfile : homebrew_gemfile,
        is_docs_lock ? homebrew_docs_gemfile_lock : homebrew_gemfile_lock,
        false,
      ).locked_gems.bundler_version
      puts "Running bundle update (with Bundler #{bundler_version})..."
      system "bundle", "update", "--ruby", "--bundler=#{bundler_version}", "--quiet", out: "/dev/null"
    end
  end
end
# rubocop:enable Homebrew/NegateInclude

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
