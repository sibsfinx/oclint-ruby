#!/usr/bin/env ruby
require 'json'
require 'optparse'

# Wrapper to run commands
def run_cmd(cmd, verbose = false)
  puts "  [executing] #{cmd}" if verbose
  %x[ #{cmd} ]
end

# Get the project top level directory absolute path
def top_level_dir
  %x[git rev-parse --show-toplevel].strip
end

# Get OCLint bin directory if it exists - abort otherwise
def oclint_bin_dir
  oclint = `which oclint`.strip
  oclint_bin = File.expand_path("..", oclint)
  abort("oclint not found in '#{oclint_bin}'") unless File.directory?(oclint_bin)
  return oclint_bin
end

def generate_xcodebuild_commands(workspace, scheme, verbose = false)
  cmd = "xcodebuild -dry-run -sdk iphonesimulator"
  cmd += " -workspace '#{workspace}'" if workspace
  cmd += " -scheme '#{scheme}'" if scheme
  cmd += " clean build > xcodebuild.log 2>/dev/null"
  puts "Generating build commands"
  run_cmd(cmd, verbose)
  abort "Failed generating build commands - comman ran was : '#{cmd}'" unless $? == 0
  puts "  XCode build commands saved as xcodebuild.log" if verbose
end

def convert_xcodebuild_to_json(verbose = false)
  cmd = "#{oclint_bin_dir}/oclint-xcodebuild xcodebuild.log"
  puts "Converting xcodebuilt output to json"
  run_cmd(cmd, verbose)
  abort "Failed converting xcodebuild output to json - command ran was : '#{cmd}'" unless $? == 0
end

def list_origin_diff_files(branch, verbose = false)
  cmd = "git diff origin/#{branch} --name-only"
  puts "Generating list of files that differ from origin"
  output = run_cmd(cmd, verbose)
  diff_files = output.lines.select {|l| l[/\.m$/]}.map {|y| y.strip}
  puts "  " + diff_files.join("\n - ") if verbose
  puts 'No files to examine!' if diff_files.empty?
  return diff_files
end

def do_incremental_lint(branch, format, verbose)
  new_files = list_origin_diff_files(branch, verbose)
  return '' if new_files.empty?
  cmd = "#{oclint_bin_dir}/oclint --report-type #{format} " + new_files.join(' ') + " 2>/dev/null"
  puts "Running incremental linter"
  output = run_cmd(cmd, verbose)
  abort "Failed incremental full linter - command ran was : '#{cmd}'" unless $? == 0
  return output
end

def do_full_lint(format, verbose)
  cmd = "#{oclint_bin_dir}/oclint-json-compilation-database -e Pods -- --report-type #{format} -max-priority-1=99999 -max-priority-2=99999 -max-priority-3=99999"
  puts "Running full linter"
  output = run_cmd(cmd, verbose)
  abort "Failed running full linter - command ran was : '#{cmd}'" unless $? == 0
  return output
end

def aggregate_violation_by_file(violations)
  all_violations = Hash.new {|hash, key| hash[key] = []}
  violations.each do |violation|
    path = violation["path"]
    all_violations[path] << violation
  end
  return all_violations
end

def filter_violations_since_commit(violations_path, sha)
  changed_lines = {}
  violations_path.each do |path|
    lines = %x[ git blame -s --abbrev=0 #{sha}^..HEAD #{path} | grep -v "^\^" ].lines
    if $?.exitstatus == 0
      changed_lines[path] = lines.map { |line| line.split(')', 2)[0].strip.to_i }.uniq
    end
  end
  return changed_lines
end

def filter_violations_by_path_and_line_number(all_violations, changed_lines)
  violations = {}
  changed_lines.each do |path, lines|
    violations[path] = all_violations[path].find_all do |v|
      lines.include? v["startLine"]
    end
  end
  return violations
end

def violations_summary(violations)
  return "Summary: %{badFiles}/%{totalFiles} files with violations (%{summary})" % {
    :badFiles => violations.count { |k, v| v.any? },
    :totalFiles => violations.count,
    :summary => (1..3).map do |p|
      count = violations.map { |k, v| v.count { |o| o['priority'] == p } }.inject(:+)
      "P%d: %d" % [p, count || 0]
    end.join(', ')
  }
end


#def get_violations_details(violations)
def json_to_text(violations)
  return '' if violations.length == 0
  prefix = top_level_dir + '/'
  violations_details = []
  violations.each do |path, details|
    next if details.length == 0
    path = path[prefix.length..-1] if path.start_with?(prefix)
    violations_details << path
    details.sort_by { |d| d['startLine'] }.each do |v|
      violations_details << "  #{v['startLine']}: #{v['rule']} (P#{v['priority']}) #{v['message']}"
    end
  end
  return violations_details.join("\n")
end


def json_to_pmd(violations)
  violations = [] if violations.length == 0

  violations_details = ['<pmd version="oclint-0.8dev">']
  violations.each do |path, details|
    next if details.length == 0
    details.sort_by { |d| d['startLine'] }.each do |v|

      violations_details << "<file name=\"#{path}\">"
      violation = "  <violation"
      ["startColumn", "endColumn", "startLine", "endLine", "priority", "rule"].each do |k|
        violation += " #{k.gsub('start', 'begin').downcase}=\"#{v[k]}\""
      end
      violation+= ">#{v['message']}</violation>"
      violations_details << violation
      violations_details << "</file>"
    end
  end
  violations_details << "</pmd>"
  return violations_details.join("\n")
end

def report_new_violations(json_violations)
  return '' if json_violations.length == 0

  report = JSON.load(json_violations)

  all_violations = aggregate_violation_by_file(report['violation'])

  pr_base = %x[ git log origin/master..HEAD --reverse --format="%H" | head -1 ].strip

  changed_lines = filter_violations_since_commit(all_violations.keys, pr_base)

  violations = filter_violations_by_path_and_line_number(all_violations, changed_lines)

  return violations
end

def parse_arguments
  options = {
    :skip_generation     => false,
    :branch              => 'master',
    :use_diff            => false,
    :scheme              => nil,
    :workspace           => nil,
    :format              => 'text',
    :new_violations_only => false,
    :verbose             => false,
    :output              => nil
  }

  OptionParser.new do |o|
    o.banner = "Usage: #{$0} [options]"
    o.separator  ""
    o.separator  "Examples:"
    o.separator  "     lint -s 'Demo'              # Lint the 'Demo' xcode scheme"
    o.separator  "     lint -w 'Demo.xcworkspace'  # Use the 'Demo.xcworkspace' workspace"
    o.separator  "     lint -i                     # Run in fast mode"
    o.separator  "     lint -d -b release/1.0      # Only lint the diff against the release/1.0 branch"
    o.separator  "     lint -d -n                  # Run lint against origin/master and report new committed unpushed violations"
    o.separator  ""
    o.separator  "Options"

    o.on('-i', '--incremental',
         "Run the lint operation, but don't update the compile commands database that oclint uses to determine how to " \
         "build each file.  Do this if you're confident that the xcode project hasn't changed since the last time you linted.") {
            options[:skip_generation] = true
    }

    o.on('-d', '--diff',
         "Only lint the files that have changed according to git diff origin/<somebranch>. See the -b flag to specify a branch") {
            options[:use_diff] = true
    }

    o.on('-b', '--branch [BRANCH]', String,
         "Use this in conjunction with -d to choose what branch to diff against. Default is master.") {|b|
            options[:branch] = b
    }

    o.on('-s', '--scheme [SCHEME]', String,
         "choose the xcode scheme to lint against. default is i#{options[:scheme]}.") {|s|
            options[:scheme] = s
    }

    o.on('-w', '--workspace [WORKSPACE]', String,
         "choose the xcode workspace to lint against. default is i#{options[:workspace]}.") {|w|
            options[:workspace] = w
    }

    o.on('-f', '--format [FORMAT]', String,
         "'text' (default), 'json', 'html', 'xml', or 'pmd'.  See
          http://docs.oclint.org/en/dev/customizing/reports.html") {|f|
            options[:format] = f
    }

    o.on('-o', '--output [PATH]', String,
         "Path to where the results should be saved (defaults to screen)") {|p|
            options[:output] = p
    }

    o.on('-n', '--new-only',
         "Report new violations only since origin/$branch (see -d and -b flags)") {
            options[:new_violations_only] = true
            options[:use_diff]
    }

    o.on('-v', '--verbose',"print commands executed to screen") {options[:verbose] = true}

    o.on('-h', '--help') { puts o; exit }
    o.parse!
  end
  return options
end


if __FILE__ == $0
  options = parse_arguments

  options[:new_violations_only] == true ? report_format = 'json' : report_format = options[:format]

  unless options[:skip_generation]
    generate_xcodebuild_commands(options[:workspace], options[:scheme], options[:verbose]  )
    convert_xcodebuild_to_json(options[:verbose])
  end

  if options[:use_diff]
    violations = do_incremental_lint(options[:branch], report_format, options[:verbose])
  else
    violations = do_full_lint(report_format, options[:verbose])
  end

  if options[:new_violations_only]
    violations = report_new_violations(violations)
  end

  # For now we just support pmd, text and json output
  if options[:output]

    if options[:format] == 'pmd'
      output = json_to_pmd(violations)
    elsif options[:format] == 'json'
      output = JSON.pretty_generate(violations)
    else
      output = json_to_text(violations)
    end

    File.open(options[:output], 'w') { |file| file.write(output) }
  end

  if violations.length > 0
    puts
    puts
    puts violations_summary(violations)
    puts
    puts
    details = json_to_text(violations)
    puts details
    exit 1 if details.strip != ''
  else
    puts 'No lint violations detected'
  end
end

