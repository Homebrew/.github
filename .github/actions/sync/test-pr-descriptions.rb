# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "yaml"

Dir.chdir(File.expand_path("../../..", __dir__))
steps = YAML.load_file(".github/workflows/check-prs.yml").fetch("jobs").fetch("manage").fetch("steps")
steps = steps.drop_while { |step| step["name"] != "Check pull request template" }
abort "Missing pull request checker" if steps.empty?

template = <<~MARKDOWN
  # What and why
  <!-- Describe the change. -->
  Please keep the following checklist:
  - [ ] I followed the guidelines.
  - [ ] I checked for duplicates.
  - [ ] I tested the change.
  - [ ] I disclosed AI usage.
  ## Screenshots
  | Before | After |
  | --- | --- |
  | <!-- Add screenshot. --> | <!-- Add screenshot. --> |
  -----
MARKDOWN
description_marker = "<!-- missing-pr-description -->"
template_marker = "<!-- incomplete-pr-template -->"
comment = lambda do |id, body, author = "github-actions[bot]"|
  { "id" => id, "body" => body, "user" => { "login" => author } }
end
assert = lambda do |condition, message|
  abort message unless condition
end

Dir.mktmpdir("pr-descriptions") do |workdir|
  FileUtils.mkdir_p(["#{workdir}/bin", "#{workdir}/check-prs"])
  FileUtils.cp(".github/scripts/check_template.rb", "#{workdir}/check_template.rb")
  File.write("#{workdir}/check-prs/template", template)
  # Execute the workflow's shell and jq filters, with every GitHub request kept local.
  File.write("#{workdir}/bin/gh", <<~'RUBY')
    #!/usr/bin/env ruby
    require "json"
    require "open3"

    abort "Expected gh api" unless ARGV.shift == "api"
    state_path = "#{ENV.fetch("RUNNER_TEMP")}/github.json"
    state = JSON.parse(File.read(state_path))
    method = "GET"
    if ARGV.first == "--method"
      ARGV.shift
      method = ARGV.shift
    end
    ARGV.shift if ARGV.first == "--paginate"
    path = ARGV.shift
    response = case [method, path]
    in ["GET", %r{\Arepos/[^/]+/[^/]+/issues/42/comments\z}]
      state.fetch("comments")
    in ["GET", %r{\Arepos/[^/]+/[^/]+/issues/42\z}]
      { "closed_by" => { "login" => state.fetch("closed_by") } }
    in ["POST", %r{\Arepos/[^/]+/[^/]+/issues/42/comments\z}]
      abort "Expected comment body" unless ARGV.shift == "--raw-field"
      body = ARGV.shift.delete_prefix("body=")
      state["next_id"] += 1
      comment = { "id" => state["next_id"], "body" => body, "user" => { "login" => "github-actions[bot]" } }
      state["comments"] << comment
      state["mutations"] << [method, path]
      comment
    in ["DELETE", %r{\Arepos/[^/]+/[^/]+/issues/comments/\d+\z}]
      state["comments"].reject! { |comment| comment["id"] == path.split("/").last.to_i }
      state["mutations"] << [method, path]
      nil
    in ["PATCH", %r{\Arepos/[^/]+/[^/]+/pulls/42\z}]
      abort "Expected pull request state" unless ARGV.shift == "-f"
      state["state"] = ARGV.shift.delete_prefix("state=")
      state["closed_by"] = "github-actions[bot]" if state["state"] == "closed"
      state["mutations"] << [method, path]
      nil
    else
      abort "Unexpected GitHub request: #{method} #{path}"
    end
    File.write(state_path, JSON.generate(state))
    if ARGV.first == "--jq"
      ARGV.shift
      output, status = Open3.capture2("jq", "-r", ARGV.shift, stdin_data: JSON.generate(response))
      abort "jq failed" unless status.success?
      print output
    end
    abort "Unexpected arguments: #{ARGV}" unless ARGV.empty?
  RUBY
  FileUtils.chmod(0755, "#{workdir}/bin/gh")

  run_workflow = lambda do |body, title: "Fix formula bug", repository: "Homebrew/brew", previous: nil|
    state = previous || { "state" => "open", "closed_by" => "", "comments" => [], "next_id" => 100 }
    state["mutations"] = []
    File.write("#{workdir}/github.json", JSON.generate(state))
    File.write("#{workdir}/check-prs/body", body)
    values = { "github.event.pull_request.state" => state.fetch("state") }
    env = {
      "PATH"              => "#{workdir}/bin:#{ENV.fetch("PATH")}",
      "RUNNER_TEMP"       => workdir,
      "GITHUB_OUTPUT"     => "#{workdir}/output",
      "GITHUB_REPOSITORY" => repository,
      "GH_TOKEN"          => "local-test",
      "PR_NUMBER"         => "42",
      "PR_TEMPLATE_URL"   => "https://github.com/#{repository}/blob/main/.github/PULL_REQUEST_TEMPLATE.md",
    }
    steps.each do |step|
      # Support conjunctions of comparisons or parenthesized disjunctions only.
      # Reject ungrouped OR rather than silently giving it precedence over AND.
      # Parse every comparison, even when an earlier result would short-circuit.
      enabled = step.fetch("if", "").split("&&").map do |conjunction|
        conjunction = conjunction.strip
        if conjunction.include?("||") && !conjunction.match?(/\A\([^()]+\)\z/)
          abort "Unsupported ungrouped OR: #{conjunction}"
        end

        conjunction.delete_prefix("(").delete_suffix(")").split("||").map do |comparison|
          match = comparison.strip.match(/\A([\w.]+) (==|!=) '([^']*)'\z/)
          abort "Unsupported condition: #{comparison}" unless match

          equal = values.fetch(match[1], "") == match[3]
          (match[2] == "==") ? equal : !equal
        end.any?
      end.all?
      values["steps.#{step["id"]}.outcome"] = enabled ? "success" : "skipped"
      next unless enabled

      step_env = step.fetch("env", {}).transform_values do |value|
        if value != "${{ github.event.pull_request.title }}"
          abort "Unexpected environment binding: #{value}"
        end

        title
      end
      File.write(env.fetch("GITHUB_OUTPUT"), "")
      output, status = Open3.capture2e(env.merge(step_env), "bash", "-euo", "pipefail", "-c", step.fetch("run"))
      assert.call(status.success?, "#{step.fetch("name")} failed: #{output}")
      File.readlines(env.fetch("GITHUB_OUTPUT"), chomp: true).each do |line|
        key, value = line.split("=", 2)
        values["steps.#{step["id"]}.outputs.#{key}"] = value
      end
    end
    JSON.parse(File.read("#{workdir}/github.json"))
  end
  reminders = lambda do |state|
    state.fetch("comments").select do |item|
      item.dig("user", "login") == "github-actions[bot]" && item.fetch("body").include?(description_marker)
    end
  end

  checked_template = template.gsub("- [ ]", "- [x]")
  [template, checked_template, template.gsub("- [ ]", "- [X]"),
   " \r\n#{checked_template}\n<!-- Hidden\nexplanation -->\n\t",
   "#{template}\n<!-- Unclosed hidden explanation",
   "#{template}\n---\n",
   checked_template.gsub("I followed", "I\tfollowed").gsub("guidelines.", "guidelines.  "),
   template.sub("- [ ] I tested the change.\n", ""),
   template.gsub("<!-- Add screenshot. -->", "")].each do |body|
    state = run_workflow.call(body)
    assert.call(state["state"] == "open", "A template-only PR was closed")
    assert.call(reminders.call(state).length == 1, "Missing description reminder for #{body.inspect}")
    assert.call(state["mutations"].map(&:first) == ["POST"], "A reminder changed more than the comment")
  end

  without_screenshots = template.sub(
    "| Before | After |\n| --- | --- |\n| <!-- Add screenshot. --> | <!-- Add screenshot. --> |",
    "Not applicable: this fixes a command-line crash without changing the UI.",
  )
  ["Fixes a crash when the formula has no dependencies.\n#{template}",
   "#{template}\n<!-- context --> Fixes a crash. <!-- detail -->",
   template.sub("Please keep the following checklist:", "Fixes a crash when loading an empty list."),
   without_screenshots].each do |body|
    state = run_workflow.call(body)
    assert.call(state["state"] == "open" && state["mutations"].empty?, "A described PR was changed")
  end

  state = run_workflow.call(template)
  state["comments"] << comment.call(1, description_marker, "contributor")
  state["comments"] << comment.call(2, "An unrelated bot comment.")
  state = run_workflow.call(checked_template, previous: state)
  assert.call(state["mutations"].empty?, "Editing checkboxes duplicated a reminder")
  state["comments"] << comment.call(3, description_marker)
  state = run_workflow.call("#{template}\nFixes a crash.", previous: state)
  assert.call(state["comments"].map { |item| item["id"] } == [1, 2],
              "Cleanup removed unrelated comments or missed duplicates")
  assert.call(state["mutations"].map(&:first) == ["DELETE", "DELETE"], "Description cleanup changed PR state")

  state = run_workflow.call("")
  assert.call(state["state"] == "closed" && reminders.call(state).empty?, "An empty PR escaped the template check")
  assert.call(state["comments"].one? { |item| item["body"].include?(template_marker) },
              "Missing template closure comment")
  state = run_workflow.call(template, previous: state)
  assert.call(state["state"] == "open", "Restoring the template did not reopen the PR")
  assert.call(state["comments"].length == 1 && reminders.call(state).length == 1,
              "A reopened template-only PR did not get only the description reminder")
  state = run_workflow.call("#{template}\nFixes a crash.", previous: state)
  assert.call(state["state"] == "open" && state["comments"].empty?, "Completing the description did not clean up")

  state = run_workflow.call(template)
  state = run_workflow.call("", previous: state)
  assert.call(state["state"] == "closed" && state["comments"].length == 2,
              "Stripping the template did not retain the reminder and add the closure comment")
  state = run_workflow.call("#{template}\nFixes a crash.", previous: state)
  assert.call(state["state"] == "open" && state["comments"].empty?,
              "Restoring the template with a description did not reopen and remove both comments")

  ["maintainer", "github-actions[bot]"].each do |closer|
    state = { "state" => "closed", "closed_by" => closer,
              "comments" => [], "next_id" => 100 }
    state = run_workflow.call(template, previous: state)
    assert.call(state["state"] == "closed" && state["mutations"].empty?,
                "A closed PR without markers received a reminder")
    state["comments"] << comment.call(1, description_marker)
    state = run_workflow.call(template, previous: state)
    assert.call(state["state"] == "closed" && state["mutations"].empty?,
                "A description reminder reopened a closed PR")
  end
  state = { "state" => "closed", "closed_by" => "maintainer",
            "comments" => [comment.call(1, template_marker)], "next_id" => 100 }
  state = run_workflow.call(template, previous: state)
  assert.call(state["state"] == "closed" && reminders.call(state).empty?, "A maintainer closure was overridden")

  %w[brew homebrew-core homebrew-cask BrewUI].each do |repository|
    repo = "Homebrew/#{repository}"
    state = run_workflow.call(template, repository: repo)
    assert.call(reminders.call(state).length == 1, "#{repo} did not get a reminder")
    state = run_workflow.call("Reverts #{repo}#123", title: 'Revert "Fix formula bug"', repository: repo)
    assert.call(state["state"] == "open" && state["mutations"].empty?, "A generated revert was changed")
  end
  bump_bodies = [
    "Created with `brew bump`",
    "Created by `brew bump-formula-pr`",
    "Created with `brew bump-cask-pr`",
    "Created by https://github.com/mislav/bump-homebrew-formula-action",
  ]
  %w[homebrew-core homebrew-cask].each do |repository|
    bump_bodies.each do |body|
      state = run_workflow.call(body, repository: "Homebrew/#{repository}")
      assert.call(state["state"] == "open" && state["mutations"].empty?, "A recognized bump PR was changed")
    end
    state = run_workflow.call(template, repository: "Homebrew/#{repository}")
    state = run_workflow.call(bump_bodies.first, repository: "Homebrew/#{repository}", previous: state)
    assert.call(state["state"] == "open" && state["comments"].empty?,
                "A recognized bump description did not resolve the reminder")
    assert.call(state["mutations"].map(&:first) == ["DELETE"], "Resolving a bump reminder changed PR state")
  end
end

puts "Pull request description checks passed."
