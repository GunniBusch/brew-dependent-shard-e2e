#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "set"
require "time"
require "uri"

SOURCE_URL = "https://formulae.brew.sh/api/formula.json"
OUTPUT_PATH = File.expand_path("../docs/data/formula-graph.json", __dir__)


def fetch_formula_json
  uri = URI(SOURCE_URL)
  response = Net::HTTP.get_response(uri)
  unless response.is_a?(Net::HTTPSuccess)
    warn "Failed to fetch #{SOURCE_URL}: #{response.code} #{response.message}"
    exit 1
  end

  JSON.parse(response.body)
end


def normalize_formula(raw)
  {
    "name" => raw.fetch("name"),
    "full_name" => raw.fetch("full_name", raw.fetch("name")),
    "runtime_deps" => Array(raw["dependencies"]).sort,
    "build_deps" => Array(raw["build_dependencies"]).sort,
    "test_deps" => Array(raw["test_dependencies"]).sort,
    "bottle_tags" => Array(raw.dig("bottle", "stable", "files")&.keys).sort,
    "deprecated" => !!raw["deprecated"],
    "disabled" => !!raw["disabled"],
  }
end


def append_reverse_edges!(reverse_map, source_name, dependency_names)
  dependency_names.each do |dependency_name|
    reverse_map[dependency_name] ||= []
    reverse_map[dependency_name] << source_name
  end
end


def main
  started = Time.now
  raw_formulae = fetch_formula_json
  normalized_formulae = raw_formulae.map { |raw| normalize_formula(raw) }

  reverse_runtime = {}
  reverse_build = {}
  reverse_test = {}

  normalized_formulae.each do |formula|
    name = formula.fetch("name")
    append_reverse_edges!(reverse_runtime, name, formula.fetch("runtime_deps"))
    append_reverse_edges!(reverse_build, name, formula.fetch("build_deps"))
    append_reverse_edges!(reverse_test, name, formula.fetch("test_deps"))
  end

  [reverse_runtime, reverse_build, reverse_test].each_value do |dependents|
    dependents.uniq!
    dependents.sort!
  end

  payload = {
    "generated_at" => Time.now.utc.iso8601,
    "source" => SOURCE_URL,
    "formula_count" => normalized_formulae.length,
    "formulae" => normalized_formulae,
    "reverse_runtime" => reverse_runtime,
    "reverse_build" => reverse_build,
    "reverse_test" => reverse_test,
  }

  File.write(OUTPUT_PATH, JSON.generate(payload))

  elapsed = (Time.now - started).round(2)
  puts "Wrote #{OUTPUT_PATH} (#{normalized_formulae.length} formulae, #{elapsed}s)"
end

main
