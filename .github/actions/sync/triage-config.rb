#!/usr/bin/env ruby

require 'fileutils'
require 'open3'
require 'pathname'

def git(*args)
  system 'git', *args
  exit $?.exitstatus unless $?.success?
end

target_dir = Pathname(ARGV[0])
source_dir = ARGV[1]

puts 'Detecting changes…'
[
  '.github/workflows/lock-threads.yml',
  '.github/workflows/stale-issues.yml',
].each do |glob|
  src_paths = Pathname.glob(glob)
  dst_paths = Pathname.glob(target_dir.join(glob))

  dst_paths.each do |path|
    FileUtils.rm_f path
  end

  src_paths.each do |path|
    target_dir.join(path.dirname).mkpath
    FileUtils.cp path, target_dir.join(path)
  end
end

out, err, status = Open3.capture3('git', '-C', target_dir.to_s, 'status', '--porcelain', '--ignore-submodules=dirty')
raise err unless status.success?

target_dir_changed = !out.chomp.empty?

unless target_dir_changed
  puts 'No changes detected.'
  exit
end

git '-C', target_dir.to_s, 'add', '--all'

out, err, status = Open3.capture3('git', '-C', target_dir.to_s, 'diff', '--name-only', '--staged')
raise err unless status.success?

modified_paths = out.lines.map(&:chomp)

modified_paths.each do |modified_path|
  puts "Detected changes to #{modified_path}."
  git '-C', target_dir.to_s, 'commit', modified_path, '--message', "#{File.basename(modified_path)}: update to match main configuration", '--quiet'
end
puts

File.open(ENV.fetch('GITHUB_OUTPUT'), 'a') do |f|
  f.puts 'pull_request=true'
end
