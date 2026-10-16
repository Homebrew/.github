# frozen_string_literal: true

require "bundler"
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

# Subprocess fixtures for the standalone sync script.
module SharedConfigHelpers
  def prepare_target(directory)
    write(".ruby-version", "4.0.6\n", directory:)
    write(".rubocop.yml", "# original configuration\n", directory:)
    git("init", "--quiet", directory:)
    git("config", "user.name", "Test", directory:)
    git("config", "user.email", "test@example.invalid", directory:)
    git("config", "commit.gpgsign", "false", directory:)
    git("config", "core.hooksPath", File::NULL, directory:)
  end

  def write(path, contents = "", directory: target)
    path = directory/path
    path.dirname.mkpath
    path.write(contents)
  end

  def run_command(*args, env: {}, **options)
    # Do not pass bundle exec's Gemfile, RUBYOPT or PATH into the standalone script.
    Bundler.with_unbundled_env do
      env = {
        "PATH"             => "#{workdir}/bin:#{File.dirname(RbConfig.ruby)}:#{ENV.fetch("PATH")}",
        "BUNDLE_TEST_ARGS" => bundle_args.to_s,
        "GITHUB_ACTIONS"   => nil,
        "GITHUB_OUTPUT"    => nil,
      }.merge(env)
      Open3.capture2e(env, *args, chdir: source_repository, **options)
    end
  end

  def successful_command(*args, **options)
    output, status = run_command(*args, **options)
    expect(status).to be_success, "#{args.join(" ")} failed (#{status.exitstatus}):\n#{output}"
    output
  end

  def git(*args, directory: target)
    successful_command("git", "-C", directory.to_s, *args).chomp
  end

  def commit_fixture(directory: target)
    git("add", "--all", directory:)
    git("commit", "--quiet", "--message", "Fixture", directory:)
  end

  def sync_target(*args, directory: target, **options)
    bundle_args.write("")
    successful_command(RbConfig.ruby, ".github/actions/sync/shared-config.rb",
                       directory.to_s, brew_repository.to_s, *args, **options)
  end

  def expect_sync_failure(*messages)
    head = git("rev-parse", "HEAD")
    output, status = run_command(RbConfig.ruby, ".github/actions/sync/shared-config.rb",
                                 target.to_s, brew_repository.to_s)
    expect(status).not_to be_success, output
    messages.each { |message| expect(output).to include(message) }
    expect(git("rev-parse", "HEAD")).to eq(head)
  end

  def expect_no_ruby_config
    expect(target/".ruby-version").not_to exist
    expect(target/".rubocop.yml").not_to exist
  end

  def expect_no_bundle
    expect(bundle_args.read).to be_empty
  end

  def expect_bundle_update(ruby: true)
    bundler_version = (brew_repository/"Library/Homebrew/Gemfile.lock").read
                      .split("BUNDLED WITH\n").last.strip
    args = ["update", *(ruby ? ["--ruby"] : []), "--bundler=#{bundler_version}", "--quiet"]
    expect(bundle_args.readlines(chomp: true)).to eq(args)
  end

  def expect_idempotent_sync(*args)
    head = git("rev-parse", "HEAD")
    sync_target(*args)
    expect(git("rev-parse", "HEAD")).to eq(head)
  end

  def expect_coderabbit_config(opted_in: false, directory: target)
    successful_command("node", "-", (directory/coderabbit_config).to_s, opted_in.to_s, stdin_data: <<~'JS')
      const assert = require("node:assert/strict");
      const fs = require("node:fs");
      const vm = require("node:vm");
      const source = fs.readFileSync(process.argv[2], "utf8");
      const optedIn = process.argv[3] === "true";
      const sandbox = { defineConfig: (config) => config };
      vm.runInNewContext(source
        .replace(/^import \{ defineConfig \} from "@coderabbitai\/config"\n/m, "")
        .replace("export default ", "globalThis.config = "), sandbox);

      for (const fullName of ["Homebrew/advisory-database", "homebrew/advisory-database", "Homebrew/other"]) {
        for (const author of ["p-linnane", "P-Linnane", "P-LINNANE", "someone-else", null]) {
          const config = sandbox.config({ repo: { fullName }, pr: author === null ? null : { author } });
          const expected = optedIn && author !== null && author.toLowerCase() === "p-linnane";
          assert.equal(config.reviews.request_changes_workflow, expected, `${fullName}: ${author}`);
          assert.equal(config.inheritance, true);
          assert.equal(Object.hasOwn(config.reviews, "allow_author_approval"), false);
        }
      }
      assert.ok(!source.includes("advisory-database"), "Repository selection belongs in the sync script");
      if (!optedIn) assert.ok(!source.includes("p-linnane"), "Do not distribute another repository's author list");
    JS
  end

  def synced_contents(path)
    contents = (source_repository/path).read
    if contents.start_with?("#!")
      shebang, contents = contents.split("\n", 2)
      "#{shebang}\n#{sync_header}#{contents}"
    else
      sync_header + contents
    end
  end
end

# Run with brew's bundled RSpec; BREW_REPOSITORY may point at a clean brew snapshot.
RSpec.describe "shared configuration sync" do
  include SharedConfigHelpers

  let(:source_repository) { Pathname(__dir__).join("../../..").realpath }
  let(:brew_repository) { Pathname(ENV.fetch("BREW_REPOSITORY")).realpath }
  let(:workdir) { Pathname(Dir.mktmpdir("shared-config-")) }
  let(:repository) { "no-ruby" }
  let(:target) { workdir/repository }
  let(:bundle_args) { workdir/"bundle-args" }
  let(:sync_header) { "# This file is synced from the `.github` repository, do not modify it directly.\n" }
  let(:codeowners) { ".github/CODEOWNERS" }
  let(:coderabbit_config) { ".coderabbit.config.ts" }
  let(:codeowners_template) { (source_repository/".github/actions/sync/codeowners.template").read }
  let(:expected_codeowners) { sync_header + codeowners_template }
  let(:expected_coderabbit_config) do
    reference = workdir/"reference"
    prepare_target(reference)
    commit_fixture(directory: reference)
    sync_target(directory: reference)
    expect_coderabbit_config(directory: reference)
    (reference/coderabbit_config).read
  end
  let(:own_codeowners) do
    entries = codeowners_template.lines.reject { |line| line.start_with?("#") }
                                 .map { |line| "#{line.chomp} @MikeMcQuaid\n" }.join
    "docs/Support-Tiers.md  @Homebrew/lead-maintainers @MikeMcQuaid\n#{entries}"
  end
  let(:incomplete_codeowners) do
    entries = own_codeowners.lines.reject { |line| line.include?("coderabbit*") }.join
    "#{entries}/.coderabbit*  @Homebrew/maintainers\n"
  end
  let(:original_gemfile) { "source \"https://rubygems.org\"\n\nruby file: \".ruby-version\"\n\ngem \"rake\"\n" }
  let(:custom_gemfile) { "source \"https://rubygems.org\"\n\ngem \"rake\"\n" }
  let(:expected_gemfile) do
    ruby_requirement = (brew_repository/"docs/Gemfile").read.lines.grep(/^ruby /).fetch(0).chomp
    "source \"https://rubygems.org\"\n\n#{ruby_requirement}\n\ngem \"rake\"\n"
  end
  let(:template_workflows) { %w[check-issues check-prs] }
  let(:license_paths) do
    %w[.github/denied-licenses.txt .github/workflows/licenses.yml .github/scripts/check-licenses.sh]
  end

  before do
    (workdir/"bin").mkpath
    # Test configuration selection and migration order without installing dependencies.
    (workdir/"bin/bundle").write <<~'SH'
      #!/bin/sh
      printf '%s\n' "$@" >> "$BUNDLE_TEST_ARGS"
      for arg in "$@"; do
        if [ "$arg" = --ruby ] && [ -f Gemfile ] && grep -q '^ruby file: "\.ruby-version"$' Gemfile; then
          echo 'Ruby requirement must be migrated before updating the lockfile.' >&2
          exit 1
        fi
      done
    SH
    (workdir/"bin/bundle").chmod(0755)
    prepare_target(target)
  end

  after do
    FileUtils.remove_entry(workdir)
  end

  it "removes Ruby configuration and installs CodeRabbit and CODEOWNERS without Ruby files, repeatedly" do
    commit_fixture
    2.times do
      sync_target
      expect_no_ruby_config
      expect_no_bundle
    end
    expect_coderabbit_config
    expect((target/coderabbit_config).read).to eq(expected_coderabbit_config)
    expect((target/codeowners).read).to eq(expected_codeowners)
  end

  it "appends pull request output on Actions only when the sync changes files" do
    output_file = workdir/"github-output"
    output_file.write("existing=value\n")
    env = { "GITHUB_ACTIONS" => "true", "GITHUB_OUTPUT" => output_file.to_s }
    commit_fixture
    sync_target(env:)
    expect(output_file.read).to eq("existing=value\npull_request=true\n")

    head = git("rev-parse", "HEAD")
    sync_target(env:)
    expect(git("rev-parse", "HEAD")).to eq(head)
    expect(output_file.read).to eq("existing=value\npull_request=true\n")
  end

  it "leaves GitHub output untouched outside Actions" do
    output_file = workdir/"github-output"
    output_file.write("existing=value\n")
    commit_fixture
    sync_target(env: { "GITHUB_OUTPUT" => output_file.to_s })
    expect(output_file.read).to eq("existing=value\n")
  end

  context "with an opted-in repository" do
    let(:repository) { "advisory-database" }

    it "replaces custom CodeRabbit and outdated synced CODEOWNERS, then makes no further commits" do
      write coderabbit_config, "export default { inheritance: false }\n"
      write codeowners, "#{sync_header}* @Homebrew/maintainers\n"
      commit_fixture
      sync_target
      expect_coderabbit_config(opted_in: true)
      expect((target/codeowners).read).to eq(expected_codeowners)
      expect_idempotent_sync
    end

    it "selects identical CodeRabbit configuration for a mixed-case repository name" do
      commit_fixture
      sync_target
      expected = (target/coderabbit_config).read
      mixed_case_target = workdir/"mixed-case/Advisory-Database"
      prepare_target(mixed_case_target)
      commit_fixture(directory: mixed_case_target)
      sync_target(directory: mixed_case_target)
      expect_coderabbit_config(opted_in: true, directory: mixed_case_target)
      expect((mixed_case_target/coderabbit_config).read).to eq(expected)
    end
  end

  %w[brew homebrew-core homebrew-cask .github].each do |name|
    context "with CodeRabbit excluded for #{name}" do
      let(:repository) { "coderabbit-excluded/#{name}" }

      it "does not install shared files or overwrite existing configuration" do
        custom_codeowners = ".coderabbit.config.ts @Homebrew/lead-maintainers\n"
        custom_config = "export default { reviews: { request_changes_workflow: false } }\n"
        write "CODEOWNERS", custom_codeowners
        commit_fixture
        sync_target
        expect(target/coderabbit_config).not_to exist
        expect(target/codeowners).not_to exist
        expect((target/"CODEOWNERS").read).to eq(custom_codeowners)
        write coderabbit_config, custom_config
        commit_fixture
        sync_target
        expect((target/coderabbit_config).read).to eq(custom_config)
      end
    end
  end

  %w[.github/CODEOWNERS CODEOWNERS docs/CODEOWNERS].each do |path|
    context "with repository-owned #{path}" do
      it "preserves complete rules with additional owners without shadowing them" do
        write path, own_codeowners
        commit_fixture
        sync_target
        expect((target/path).read).to eq(own_codeowners)
        expect_coderabbit_config
        expect((target/coderabbit_config).read).to eq(expected_coderabbit_config)
        if path != codeowners
          expect(target/codeowners).not_to exist
        end
      end

      it "rejects missing rules and wrong owners without changing the file or committing" do
        write path, own_codeowners
        commit_fixture
        sync_target
        write path, incomplete_codeowners
        commit_fixture
        expect_sync_failure("#{path} is missing these entries",
                            "/.coderabbit*  @Homebrew/lead-maintainers",
                            "/coderabbit*   @Homebrew/lead-maintainers")
        expect((target/path).read).to eq(incomplete_codeowners)
      end
    end
  end

  [[".github/CODEOWNERS", "CODEOWNERS"], ["CODEOWNERS", "docs/CODEOWNERS"]].each do |used, ignored|
    it "rejects #{ignored} shadowed by #{used} without committing" do
      write used, own_codeowners
      write ignored, own_codeowners
      commit_fixture
      expect_sync_failure("GitHub ignores #{ignored} in favour of #{used}")
      if used != codeowners
        expect(target/codeowners).not_to exist
      end
    end
  end

  %w[
    Package.swift
    Package.resolved
    Tools/Lint/Package.swift
    Tools/Lint/Package.resolved
    App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
  ].each do |filename|
    it "syncs license checks for tracked #{filename}, then removes them when it is deleted" do
      write filename
      commit_fixture
      sync_target
      license_paths.each { |path| expect((target/path).read).to eq(synced_contents(path)) }
      source_shebang = (source_repository/".github/scripts/check-licenses.sh").readlines.first
      expect(source_shebang).to start_with("#!")
      expect((target/".github/scripts/check-licenses.sh").readlines.first).to eq(source_shebang)
      expect_no_ruby_config
      expect_no_bundle
      updates = YAML.load_file(target/".github/dependabot.yml").fetch("updates")
      expect(updates.map { |update| update["package-ecosystem"] }).not_to include("swift")
      expect_idempotent_sync

      git "rm", "--quiet", filename
      commit_fixture
      sync_target
      license_paths.each { |path| expect(target/path).not_to exist }
    end
  end

  it "ignores untracked Swift manifests" do
    commit_fixture
    write "Package.swift"
    write "Package.resolved"
    sync_target
    license_paths.each { |path| expect(target/path).not_to exist }
  end

  it "keeps license checks for npm after the last Swift manifest is deleted" do
    write "Package.swift"
    write "package.json"
    commit_fixture
    sync_target
    expect((target/".github/workflows/licenses.yml").size).to be_positive
    git "rm", "--quiet", "Package.swift"
    commit_fixture
    sync_target
    license_paths.each { |path| expect((target/path).size).to be_positive }
  end

  ["lib/example.rb", "types/example.rbi", "tasks/example.rake", "example.gemspec",
   "Gemfile", "nested/Gemfile", "Gemfile.lock", "Rakefile", "lib/with\nnewline.rb"].each do |filename|
    it "installs Ruby configuration for tracked #{filename.inspect}" do
      write filename
      (target/".ruby-version").unlink
      (target/".rubocop.yml").unlink
      commit_fixture
      sync_target
      expect((target/".ruby-version").size).to be_positive
      expect((target/".rubocop.yml").size).to be_positive
      if filename == "Gemfile.lock"
        expect_bundle_update
      else
        expect_no_bundle
      end
    end
  end

  it "ignores untracked Ruby files" do
    commit_fixture
    write "untracked.rb"
    sync_target
    expect_no_ruby_config
    expect_no_bundle
  end

  it "preserves a Ruby version newer than Portable Ruby" do
    portable_version = (brew_repository/"Library/Homebrew/vendor/portable-ruby-version").read
    newer_version = "#{portable_version.split(".").first.to_i + 1}.0.0\n"
    write ".ruby-version", newer_version
    write "example.rb"
    commit_fixture
    sync_target
    expect((target/".ruby-version").read).to eq(newer_version)
    expect_idempotent_sync
  end

  %w[root root-with-lock docs shared-docs dangling-docs first-sync-docs].each do |layout|
    it "migrates the #{layout} Gemfile layout before updating lockfiles and is idempotent" do
      if %w[root root-with-lock shared-docs].include?(layout)
        write "Gemfile", original_gemfile
      end
      if layout == "root-with-lock"
        write "Gemfile.lock"
      elsif layout != "root"
        (target/"docs").mkpath
        if layout == "dangling-docs"
          FileUtils.ln_s "../Gemfile", target/"docs/Gemfile"
        else
          write "docs/Gemfile", original_gemfile
        end
        write "docs/Gemfile.lock"
        if layout == "first-sync-docs"
          FileUtils.mv target/".ruby-version", target/"docs/.ruby-version"
        end
      end
      commit_fixture
      sync_target
      if layout == "root"
        expect_no_bundle
      else
        expect_bundle_update
      end
      if %w[docs dangling-docs first-sync-docs].include?(layout)
        expect(target/"Gemfile").not_to exist
        expect(target/"docs/Gemfile").not_to be_symlink
        expect((target/"docs/Gemfile").read).to eq((brew_repository/"docs/Gemfile").read)
      else
        expect((target/"Gemfile").read).to eq(expected_gemfile)
        if layout == "shared-docs"
          expect((target/"docs/Gemfile").readlink.to_s).to eq("../Gemfile")
        end
      end
      if layout == "first-sync-docs"
        expect((target/"docs/.ruby-version").readlink.to_s).to eq("../.ruby-version")
      end
      expect_idempotent_sync
      expect_no_bundle if layout == "root"
    end
  end

  %w[ruby-macho patchelf.rb].each do |name|
    context "with custom Ruby configuration in #{name}" do
      let(:repository) { name }

      it "preserves the Gemfile, Ruby version and RuboCop config and only updates Bundler" do
        write "Gemfile", custom_gemfile
        write "Gemfile.lock"
        commit_fixture
        sync_target
        expect_bundle_update(ruby: false)
        expect((target/"Gemfile").read).to eq(custom_gemfile)
        expect((target/".ruby-version").read).to eq("4.0.6\n")
        expect((target/".rubocop.yml").read).to eq("# original configuration\n")
      end
    end
  end

  context "with a custom Ruby file requirement" do
    let(:repository) { "custom-ruby-file/ruby-macho" }

    it "preserves the requirement and only updates Bundler" do
      write ".ruby-version", "#{RUBY_VERSION}\n"
      write "Gemfile", original_gemfile
      write "Gemfile.lock"
      commit_fixture
      sync_target
      expect_bundle_update(ruby: false)
      expect((target/"Gemfile").read).to eq(original_gemfile)
      expect((target/".ruby-version").read).to eq("#{RUBY_VERSION}\n")
    end
  end

  context "with brew lockfiles" do
    let(:repository) { "brew-with-lockfiles/brew" }

    it "updates only the docs lockfile" do
      %w[Gemfile.lock Library/Homebrew/Gemfile.lock docs/Gemfile.lock].each { |path| write path }
      commit_fixture
      sync_target
      expect_bundle_update
    end
  end

  context "with private docs syncing to brew" do
    let(:repository) { "private-docs/brew" }

    it "updates existing Markdown, preserves public-only files and configuration, and is idempotent" do
      private_docs = workdir/"private/docs"
      (private_docs/"nested").mkpath
      write "docs/nested/Shared.md", "Public version\n"
      write "docs/nested/Shared.markdown", "Public version\n"
      write "docs/Public.md", "Public only\n"
      write "docs/_config.yml", "Public configuration\n"
      write "docs/nested/Shared.txt", "Public text\n"
      (private_docs/"_config.yml").write("Private configuration\n")
      (private_docs/"nested/Shared.txt").write("Private text\n")
      (private_docs/"Private.txt").write("Private only\n")
      %w[md markdown].each do |extension|
        (private_docs/"nested/Shared.#{extension}").write("Private version\n")
        (private_docs/"Private.#{extension}").write("Private only\n")
      end
      commit_fixture
      sync_target "", private_docs.parent.to_s
      %w[md markdown].each do |extension|
        expect((target/"docs/nested/Shared.#{extension}").read)
          .to eq((private_docs/"nested/Shared.#{extension}").read)
        expect(target/"docs/Private.#{extension}").not_to exist
      end
      expect((target/"docs/Public.md").read).to eq("Public only\n")
      expect((target/"docs/_config.yml").read).to eq("Public configuration\n")
      expect((target/"docs/nested/Shared.txt").read).to eq("Public text\n")
      expect(target/"docs/Private.txt").not_to exist
      expect_idempotent_sync "", private_docs.parent.to_s
    end
  end

  context "with public docs syncing to private" do
    let(:repository) { "forward/private" }

    it "replaces existing Markdown with the brew source" do
      write "docs/FAQ.md", "Private version\n"
      commit_fixture
      sync_target
      expect((target/"docs/FAQ.md").read).to eq((brew_repository/"docs/FAQ.md").read)
    end
  end

  it "preserves a custom Ruby requirement" do
    write "Gemfile", "ruby \">= 3.3\"\n"
    commit_fixture
    sync_target
    expect((target/"Gemfile").read).to eq("ruby \">= 3.3\"\n")
    expect_no_bundle
  end

  context "with ci-orchestrator-private" do
    let(:repository) { "ci-orchestrator-private" }

    it "preserves custom RuboCop configuration but removes an unused Ruby version" do
      commit_fixture
      sync_target
      expect(target/".ruby-version").not_to exist
      expect((target/".rubocop.yml").read).to eq("# original configuration\n")
      expect_no_bundle
    end
  end

  %w[brew homebrew-core homebrew-cask BrewUI no-template-checks].each do |name|
    context "with template workflows in #{name}" do
      let(:repository) { name }

      it "syncs or removes issue and PR checks according to the repository" do
        template_workflows.each do |workflow|
          write ".github/workflows/#{workflow}.yml", "# Custom #{workflow} workflow\n"
        end
        commit_fixture
        sync_target
        expect_no_bundle
        template_workflows.each do |workflow|
          path = ".github/workflows/#{workflow}.yml"
          if name == "no-template-checks"
            expect(target/path).not_to exist
          else
            expect((target/path).read).to eq(synced_contents(path))
          end
        end
      end
    end
  end

  it "fails Git inspection outside a repository before modifying Ruby configuration" do
    FileUtils.rm_rf(target/".git")
    write ".ruby-version", "keep\n"
    write ".rubocop.yml", "keep\n"
    output, status = run_command(RbConfig.ruby, ".github/actions/sync/shared-config.rb",
                                 target.to_s, brew_repository.to_s, env: { "LC_ALL" => "C" })
    expect(status).not_to be_success, output
    expect(output).to include("fatal: not a git repository")
    expect((target/".ruby-version").read).to eq("keep\n")
    expect((target/".rubocop.yml").read).to eq("keep\n")
  end
end
