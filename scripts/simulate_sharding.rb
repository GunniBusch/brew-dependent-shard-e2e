#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "optparse"
require "set"
require "time"
require "fileutils"
require "uri"

SOURCE_URL = "https://formulae.brew.sh/api/formula.json"
CACHE_PATH = File.expand_path("../tmp/formula-cache.json", __dir__)
CACHE_TTL_SECONDS = 3600
EXPLAIN_ASSIGNMENT_LIMIT = 30

DEFAULTS = {
  "formula" => "openssl@3",
  "max_runners" => 4,
  "min_per_runner" => 200,
  "recursive" => true,
  "include_build" => true,
  "include_test" => true,
  "runner_tag" => "x86_64_linux",
  "core_compat" => false,
}.freeze


def parse_options
  options = DEFAULTS.dup

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: simulate_sharding.rb [options]"

    opts.on("--formula=NAME", String) { |v| options["formula"] = v }
    opts.on("--max-runners=N", Integer) { |v| options["max_runners"] = v }
    opts.on("--min-per-runner=N", Integer) { |v| options["min_per_runner"] = v }
    opts.on("--recursive=BOOL", String) { |v| options["recursive"] = v == "true" }
    opts.on("--include-build=BOOL", String) { |v| options["include_build"] = v == "true" }
    opts.on("--include-test=BOOL", String) { |v| options["include_test"] = v == "true" }
    opts.on("--runner-tag=TAG", String) { |v| options["runner_tag"] = v }
    opts.on("--core-compat=BOOL", String) { |v| options["core_compat"] = v == "true" }
  end

  parser.parse!(ARGV)

  options["max_runners"] = [options.fetch("max_runners"), 1].max
  options["min_per_runner"] = [options.fetch("min_per_runner"), 1].max
  options
end


def fetch_formulae
  uri = URI(SOURCE_URL)
  response = Net::HTTP.get_response(uri)
  raise "Failed to fetch formula data: #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)
end


def read_cached_formulae
  return nil unless File.exist?(CACHE_PATH)
  return nil if Time.now - File.mtime(CACHE_PATH) > CACHE_TTL_SECONDS

  JSON.parse(File.read(CACHE_PATH))
rescue JSON::ParserError
  nil
end


def load_formulae
  cached = read_cached_formulae
  return cached if cached

  formulae = fetch_formulae
  FileUtils.mkdir_p(File.dirname(CACHE_PATH))
  File.write(CACHE_PATH, JSON.generate(formulae))
  formulae
end


def normalize_formula(raw)
  {
    "name" => raw.fetch("name"),
    "runtime_deps" => Array(raw["dependencies"]),
    "build_deps" => Array(raw["build_dependencies"]),
    "test_deps" => Array(raw["test_dependencies"]),
    "bottle_tags" => Array(raw.dig("bottle", "stable", "files")&.keys),
  }
end


def add_reverse_edges!(map, source_name, deps)
  deps.each do |dep|
    map[dep] ||= []
    map[dep] << source_name
  end
end


def build_graph(formulae)
  normalized = formulae.map { |f| normalize_formula(f) }
  by_name = normalized.to_h { |f| [f.fetch("name"), f] }

  reverse_runtime = {}
  reverse_build = {}
  reverse_test = {}

  normalized.each do |formula|
    name = formula.fetch("name")
    add_reverse_edges!(reverse_runtime, name, formula.fetch("runtime_deps"))
    add_reverse_edges!(reverse_build, name, formula.fetch("build_deps"))
    add_reverse_edges!(reverse_test, name, formula.fetch("test_deps"))
  end

  [reverse_runtime, reverse_build, reverse_test].each do |map|
    map.each_value(&:uniq!)
    map.each_value(&:sort!)
  end

  {
    by_name:,
    reverse_runtime:,
    reverse_build:,
    reverse_test:,
  }
end


def neighbors_for(name, graph, include_build:, include_test:)
  neighbors = Set.new
  Array(graph.fetch(:reverse_runtime)[name]).each { |n| neighbors << n }
  Array(graph.fetch(:reverse_build)[name]).each { |n| neighbors << n } if include_build
  Array(graph.fetch(:reverse_test)[name]).each { |n| neighbors << n } if include_test
  neighbors.to_a.sort
end


def discover_dependents(formula_name, graph, recursive:, include_build:, include_test:)
  visited = Set.new([formula_name])
  discovered = Set.new
  queue = [formula_name]

  until queue.empty?
    current = queue.shift
    next_neighbors = neighbors_for(current, graph, include_build:, include_test:)

    next_neighbors.each do |neighbor|
      next if visited.include?(neighbor)

      visited << neighbor
      discovered << neighbor
      queue << neighbor if recursive
    end
  end

  discovered.to_a.sort
end


def compatible_with_runner?(formula, runner_tag)
  return true if runner_tag == "all"

  tags = formula.fetch("bottle_tags")
  tags.empty? || tags.include?(runner_tag) || tags.include?("all")
end


def selected_forward_deps(formula, include_build:, include_test:)
  deps = Set.new(formula.fetch("runtime_deps"))
  formula.fetch("build_deps").each { |d| deps << d } if include_build
  formula.fetch("test_deps").each { |d| deps << d } if include_test
  deps
end


def feature_set_for(formula_name, graph, include_build:, include_test:, memo:, seen: Set.new)
  memo_key = [formula_name, include_build, include_test]
  return memo[memo_key] if memo.key?(memo_key)

  formula = graph.fetch(:by_name)[formula_name]
  return [] if formula.nil?

  deps = selected_forward_deps(formula, include_build:, include_test:)
  features = Set.new

  deps.each do |dep|
    next if seen.include?(dep)

    features << dep
    next_seen = seen.dup
    next_seen << dep
    feature_set_for(dep, graph, include_build:, include_test:, memo:, seen: next_seen).each do |feature|
      features << feature
    end
  end

  memo[memo_key] = features.to_a.sort
end


def assign_shards(formula_names, dependency_features, shard_count, include_trace:)
  shard_features = Array.new(shard_count) { Set.new }
  shard_loads = Array.new(shard_count, 0)
  shard_sizes = Array.new(shard_count, 0)
  max_shard_size = [(formula_names.length.to_f / shard_count).ceil, 1].max
  shard_assignments = Array.new(shard_count) { [] }
  assignment_steps = []

  sorted = formula_names.sort_by do |name|
    features = dependency_features.fetch(name, [])
    [-features.length, name]
  end

  sorted.each_with_index do |name, step_index|
    features = dependency_features.fetch(name, [])
    feature_count = features.length
    weight = [feature_count, 1].max

    eligible_indices = shard_features.each_index.select do |idx|
      shard_sizes.fetch(idx) < max_shard_size
    end
    eligible_indices = shard_features.each_index.to_a if eligible_indices.empty?

    candidate_scores = shard_features.each_index.map do |idx|
      overlap = features.count { |feature| shard_features.fetch(idx).include?(feature) }
      {
        "shard_index" => idx + 1,
        "overlap" => overlap,
        "feature_load_before" => shard_loads.fetch(idx),
        "member_count_before" => shard_sizes.fetch(idx),
        "eligible" => eligible_indices.include?(idx),
      }
    end

    best_candidate = candidate_scores.select { |candidate| candidate.fetch("eligible") }.min_by do |candidate|
      [-candidate.fetch("overlap"),
       candidate.fetch("feature_load_before"),
       candidate.fetch("member_count_before"),
       candidate.fetch("shard_index")]
    end
    shard_index = best_candidate.fetch("shard_index") - 1

    loads_before = shard_loads.dup
    sizes_before = shard_sizes.dup

    shard_assignments.fetch(shard_index) << name
    shard_sizes[shard_index] += 1
    shard_loads[shard_index] += feature_count
    features.each { |feature| shard_features.fetch(shard_index) << feature }

    next unless include_trace

    assignment_steps << {
      "step" => step_index + 1,
      "formula" => name,
      "feature_count" => feature_count,
      "weight" => weight,
      "selected_shard_index" => shard_index + 1,
      "candidates" => candidate_scores,
      "max_shard_size" => max_shard_size,
      "capacity_constrained" => candidate_scores.any? { |candidate| !candidate.fetch("eligible") },
      "forced_by_capacity" => candidate_scores.any? do |candidate|
        !candidate.fetch("eligible") && candidate.fetch("overlap") > best_candidate.fetch("overlap")
      end,
      "loads_before" => loads_before,
      "loads_after" => shard_loads.dup,
      "sizes_before" => sizes_before,
      "sizes_after" => shard_sizes.dup,
    }
  end

  shard_assignments.each(&:sort!)
  {
    "shards" => shard_assignments,
    "shard_loads" => shard_loads,
    "sorted_dependents" => sorted.map do |name|
      feature_count = dependency_features.fetch(name, []).length
      {
        "name" => name,
        "feature_count" => feature_count,
        "weight" => [feature_count, 1].max,
      }
    end,
    "assignment_steps" => assignment_steps,
  }
end


def compute_shard_count(dependent_count, min_per_runner, max_runners)
  raw_count = dependent_count / min_per_runner
  [[raw_count, 1].max, max_runners].min
end


def run
  options = parse_options
  graph = build_graph(load_formulae)

  formula_name = options.fetch("formula")
  formula = graph.fetch(:by_name)[formula_name]
  if formula.nil?
    puts JSON.generate({ error: "Formula '#{formula_name}' not found in Homebrew API data." })
    return
  end

  discovered = discover_dependents(
    formula_name,
    graph,
    recursive: options.fetch("recursive"),
    include_build: options.fetch("include_build"),
    include_test: options.fetch("include_test"),
  )

  compatible = discovered.select do |name|
    f = graph.fetch(:by_name)[name]
    f && compatible_with_runner?(f, options.fetch("runner_tag"))
  end.sort

  filtered = (discovered - compatible).sort

  shard_count = compute_shard_count(
    compatible.length,
    options.fetch("min_per_runner"),
    options.fetch("max_runners"),
  )

  memo = {}
  dependency_features = compatible.to_h do |name|
    [name, feature_set_for(name, graph, include_build: options.fetch("include_build"),
                                  include_test: options.fetch("include_test"), memo:)]
  end

  include_assignment_explanation = compatible.length < EXPLAIN_ASSIGNMENT_LIMIT
  assignment = assign_shards(
    compatible,
    dependency_features,
    shard_count,
    include_trace: include_assignment_explanation,
  )
  shards = assignment.fetch("shards")
  shard_loads = assignment.fetch("shard_loads")

  total_tests = if options.fetch("core_compat") && shard_count > 1
    compatible.length * shard_count
  else
    compatible.length
  end

  payload = {
    generated_at: Time.now.utc.iso8601,
    formula: formula_name,
    runner_tag: options.fetch("runner_tag"),
    options: options,
    discovered_dependents_count: discovered.length,
    compatible_dependents_count: compatible.length,
    filtered_dependents_count: filtered.length,
    shard_count: shard_count,
    shards: shards.each_with_index.map do |members, idx|
      {
        shard_index: idx + 1,
        member_count: members.length,
        feature_load: shard_loads.fetch(idx),
        members: members,
      }
    end,
    dependents: compatible,
    filtered_dependents: filtered,
    total_tests_executed_estimate: total_tests,
    duplicate_work_estimate: [total_tests - compatible.length, 0].max,
  }
  if include_assignment_explanation
    payload[:assignment_explanation] = {
      limit: EXPLAIN_ASSIGNMENT_LIMIT,
      feature_load_definition: "Feature load is the sum of feature_count values for dependents assigned to a shard.",
      tie_breakers: [
        "maximize overlap first",
        "then pick lower feature load",
        "then pick fewer members",
        "then pick lower shard index",
      ],
      max_shard_size: [(compatible.length.to_f / shard_count).ceil, 1].max,
      sorted_dependents: assignment.fetch("sorted_dependents"),
      assignment_steps: assignment.fetch("assignment_steps"),
    }
  end

  puts JSON.generate(payload)
end

run
