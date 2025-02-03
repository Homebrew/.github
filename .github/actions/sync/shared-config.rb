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
dependabot_yaml = ".github/dependabot.yml"
docs_workflow_yaml = ".github/workflows/docs.yml"
actionlint_workflow_yaml = ".github/workflows/actionlint.yml"
vale_ini = ".vale.ini"

target_gemfile_lock = target_directory_path/"Gemfile.lock"

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
  key.match?(%r{\Arequire|inherit_from|inherit_mode|Cask/|Formula|Homebrew|Performance/|RSpec|Sorbet/})
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

dependabot_config_yaml = YAML.load_file(dependabot_yaml)
dependabot_config_yaml["updates"].select! do |update|
  case update["package-ecosystem"]
  when "bundler"
    target_gemfile_lock.exist?
  when "npm"
    (target_directory_path/"package.json").exist?
  when "docker"
    (target_directory_path/"Dockerfile").exist?
  when "devcontainers"
    (target_directory_path/".devcontainer/devcontainer.json").exist?
  when "pip"
    (target_directory_path/"requirements.txt").exist?
  else
    true
  end
end
dependabot_config = dependabot_config_yaml.to_yaml

custom_ruby_version_repos = %w[
  mass-bottling-tracker-private
  ruby-macho
].freeze
custom_rubocop_repos = %w[
  ci-orchestrator
  mass-bottling-tracker-private
  orka_api_client
  ruby-macho
].freeze
custom_dependabot_repos = %w[
  .github
  brew
  ci-orchestrator
].freeze
custom_docs_repos = %w[
  brew
  rubydoc.brew.sh
  ruby-macho
].freeze
custom_actionlint_repos = %w[
  brew
  homebrew-core
]
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
  ".github/workflows/stale-issues.yml",
].each do |path|
  target_path = target_directory_path/path
  target_path.dirname.mkpath

  case path
  when docs
    next if custom_docs_repos.include?(repository_name)
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

      if [ruby_version, "Gemfile", "Gemfile.lock"].include?(docs_path_basename) &&
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
      else
        FileUtils.cp docs_path, target_docs_path
      end
    end
  when docs_workflow_yaml
    next if custom_docs_repos.include?(repository_name)

    docs_path = target_directory_path/docs
    next unless docs_path.exist?
    next unless docs_path.directory?

    FileUtils.cp homebrew_docs_workflow_yaml, target_path
  when actionlint_workflow_yaml
    next if custom_actionlint_repos.include?(repository_name)

    FileUtils.cp actionlint_workflow_yaml, target_path
  when vale_ini
    next if custom_docs_repos.include?(repository_name)

    docs_path = target_directory_path/docs
    next unless docs_path.exist?
    next unless docs_path.directory?

    FileUtils.cp homebrew_vale_ini, target_path
  when ruby_version
    next if custom_ruby_version_repos.include?(repository_name)

    target_path = target_directory_path/"Library/Homebrew/#{ruby_version}" if repository_name == "brew"

    target_path.write("#{homebrew_ruby_version}\n")
  when rubocop_yaml
    next if custom_rubocop_repos.include?(repository_name)

    FileUtils.rm_f target_path
    target_path.write(
      "# This file is synced from `Homebrew/brew` by the `.github` repository, do not modify it directly.\n" \
      "#{homebrew_rubocop_config}\n",
    )
  when dependabot_yaml
    next if custom_dependabot_repos.include?(repository_name)
    next if path == target_path.to_s

    FileUtils.rm_f target_path
    target_path.write(
      "# This file is synced from the `.github` repository, do not modify it directly.\n" \
      "#{dependabot_config}\n",
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
# We don't have Homebrew exclude? method here.
# rubocop:disable Homebrew/NegateInclude
if !custom_ruby_version_repos.include?(repository_name) && target_gemfile_lock.exist?
  Dir.chdir target_directory_path do
    require "bundler"
    bundler_version = Bundler::Definition.build(homebrew_gemfile, homebrew_gemfile_lock, false)
                                         .locked_gems
                                         .bundler_version
    puts "Running bundle update (with Bundler #{bundler_version})..."
    system "bundle", "update", "--ruby", "--bundler=#{bundler_version}", "--quiet", out: "/dev/null"
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
