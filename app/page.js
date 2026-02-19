"use client";

import { useEffect, useMemo, useState } from "react";

const RUNNER_TAGS = ["x86_64_linux", "arm64_linux", "all"];
const PRESETS = ["openssl@3", "zlib", "python@3.12", "cmake", "ffmpeg", "node"];
const ANIMATION_DELAY_MS = 850;

export default function Home() {
  const [form, setForm] = useState({
    formula: "openssl@3",
    maxRunners: 4,
    minPerRunner: 200,
    runnerTag: "x86_64_linux",
    recursive: true,
    includeBuild: true,
    includeTest: true,
    coreCompat: false,
  });

  const [result, setResult] = useState(null);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const [playbackStep, setPlaybackStep] = useState(0);
  const [isPlaying, setIsPlaying] = useState(false);

  const maxShardSize = useMemo(() => {
    if (!result || !result.shard_count) return 0;
    return Math.max(...result.shards.map((shard) => shard.member_count), 0);
  }, [result]);

  const explanation = result?.assignment_explanation || null;
  const explanationSteps = explanation?.assignment_steps || [];

  useEffect(() => {
    if (!explanation) {
      setPlaybackStep(0);
      setIsPlaying(false);
      return;
    }

    setPlaybackStep(0);
    setIsPlaying(true);
  }, [result?.generated_at, explanation]);

  useEffect(() => {
    if (!explanation || !isPlaying) return;
    if (playbackStep >= explanationSteps.length) {
      setIsPlaying(false);
      return;
    }

    const timerId = setTimeout(() => {
      setPlaybackStep((value) => Math.min(value + 1, explanationSteps.length));
    }, ANIMATION_DELAY_MS);

    return () => clearTimeout(timerId);
  }, [playbackStep, isPlaying, explanation, explanationSteps.length]);

  const currentAnimatedStep = playbackStep > 0 ? explanationSteps[playbackStep - 1] : null;
  const animatedLoads = currentAnimatedStep
    ? currentAnimatedStep.loads_after
    : Array.from({ length: result?.shard_count || 0 }, () => 0);
  const animatedSizes = currentAnimatedStep
    ? currentAnimatedStep.sizes_after
    : Array.from({ length: result?.shard_count || 0 }, () => 0);
  const maxAnimatedLoad = Math.max(1, ...animatedLoads);

  const runSimulation = async () => {
    setLoading(true);
    setError("");

    try {
      const response = await fetch("/api/simulate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(form),
      });

      const payload = await response.json();
      if (!response.ok) {
        throw new Error(payload.error || "Simulation failed.");
      }

      setResult(payload);
    } catch (e) {
      setError(e.message);
      setResult(null);
    } finally {
      setLoading(false);
    }
  };

  return (
    <main className="shell">
      <div className="backdrop" aria-hidden="true" />

      <header className="hero card">
        <p className="kicker">Local Next.js Simulator</p>
        <h1>Homebrew Dependent Sharding Lab</h1>
        <p>
          Visualize how dependent sharding behaves for a formula, and see exactly what changing shard-related flags does
          to coverage and duplicate work.
        </p>
      </header>

      <section className="card controls">
        <h2>Controls</h2>

        <div className="preset-row">
          {PRESETS.map((preset) => (
            <button
              key={preset}
              type="button"
              className="chip"
              onClick={() => setForm((prev) => ({ ...prev, formula: preset }))}
            >
              {preset}
            </button>
          ))}
        </div>

        <div className="grid">
          <label>
            <span>Formula</span>
            <input
              value={form.formula}
              onChange={(event) => setForm((prev) => ({ ...prev, formula: event.target.value }))}
              placeholder="openssl@3"
            />
          </label>

          <label>
            <span>Runner Tag</span>
            <select
              value={form.runnerTag}
              onChange={(event) => setForm((prev) => ({ ...prev, runnerTag: event.target.value }))}
            >
              {RUNNER_TAGS.map((tag) => (
                <option key={tag} value={tag}>
                  {tag}
                </option>
              ))}
            </select>
          </label>

          <label>
            <span>Max Runners</span>
            <input
              type="number"
              min={1}
              value={form.maxRunners}
              onChange={(event) => setForm((prev) => ({ ...prev, maxRunners: Number(event.target.value || 1) }))}
            />
          </label>

          <label>
            <span>Min Dependents / Runner</span>
            <input
              type="number"
              min={1}
              value={form.minPerRunner}
              onChange={(event) => setForm((prev) => ({ ...prev, minPerRunner: Number(event.target.value || 1) }))}
            />
          </label>

          <label className="toggle">
            <input
              type="checkbox"
              checked={form.recursive}
              onChange={(event) => setForm((prev) => ({ ...prev, recursive: event.target.checked }))}
            />
            <span>Recursive dependents</span>
          </label>

          <label className="toggle">
            <input
              type="checkbox"
              checked={form.includeBuild}
              onChange={(event) => setForm((prev) => ({ ...prev, includeBuild: event.target.checked }))}
            />
            <span>Include build edges</span>
          </label>

          <label className="toggle">
            <input
              type="checkbox"
              checked={form.includeTest}
              onChange={(event) => setForm((prev) => ({ ...prev, includeTest: event.target.checked }))}
            />
            <span>Include test edges</span>
          </label>

          <label className="toggle">
            <input
              type="checkbox"
              checked={form.coreCompat}
              onChange={(event) => setForm((prev) => ({ ...prev, coreCompat: event.target.checked }))}
            />
            <span>Core mode without shard args</span>
          </label>
        </div>

        <div className="actions">
          <button type="button" className="primary" onClick={runSimulation} disabled={loading}>
            {loading ? "Simulating..." : "Run Simulation"}
          </button>
          <span className="hint">Backend: Ruby script executed via Next.js API route</span>
        </div>

        {error ? <p className="error">{error}</p> : null}
      </section>

      {result ? (
        <>
          <section className="stats">
            <Metric label="Dependents Found" value={result.discovered_dependents_count} />
            <Metric label="Runner-Compatible" value={result.compatible_dependents_count} />
            <Metric label="Computed Shards" value={result.shard_count} />
            <Metric label="Est. Duplicate Tests" value={result.duplicate_work_estimate} />
          </section>

          <section className="card">
            <h2>Flag Impact</h2>
            <p className="mono impact">
              formula={result.formula} | max-runners={result.options.max_runners} | min-per-runner=
              {result.options.min_per_runner} | recursive={String(result.options.recursive)} | include-build=
              {String(result.options.include_build)} | include-test={String(result.options.include_test)} | core-compat=
              {String(result.options.core_compat)}
            </p>
            <p className="mono impact">
              shard_count = clamp(floor(compatible_dependents / min_per_runner), 1, max_runners) = {result.shard_count}
            </p>
            <p className="mono impact">total_tests_executed_estimate = {result.total_tests_executed_estimate}</p>
          </section>

          {explanation ? (
            <section className="card">
              <div className="explainer-header">
                <h2>Animated Split Explanation</h2>
                <div className="explainer-actions">
                  <button type="button" className="chip" onClick={() => setIsPlaying((value) => !value)}>
                    {isPlaying ? "Pause" : "Play"}
                  </button>
                  <button
                    type="button"
                    className="chip"
                    onClick={() => {
                      setPlaybackStep(0);
                      setIsPlaying(true);
                    }}
                  >
                    Restart
                  </button>
                  <span className="pill">
                    step {Math.min(playbackStep, explanationSteps.length)}/{explanationSteps.length}
                  </span>
                </div>
              </div>

              <p className="mono impact">{explanation.feature_load_definition}</p>
              <p className="mono impact">
                tie-break order: {explanation.tie_breakers.join(" -> ")}
              </p>
              <p className="mono impact">max_shard_size (hard cap) = {explanation.max_shard_size}</p>

              <div className="animated-shards">
                {animatedLoads.map((load, index) => {
                  const width = Math.max((load / maxAnimatedLoad) * 100, load === 0 ? 0 : 4);
                  return (
                    <article className="animated-shard" key={`animated-shard-${index + 1}`}>
                      <header>
                        <strong>Shard {index + 1}</strong>
                        <span className="mono">load={load}</span>
                        <span className="mono">members={animatedSizes[index]}</span>
                      </header>
                      <div className="bar compact">
                        <span style={{ width: `${width}%` }} />
                      </div>
                    </article>
                  );
                })}
              </div>

              <ol className="explain-steps mono">
                {explanationSteps.map((step, index) => {
                  const visible = index < playbackStep;
                  const selected = step.candidates.find((candidate) => candidate.shard_index === step.selected_shard_index);
                  const candidateText = step.candidates
                    .map((candidate) => {
                      const blocked = candidate.eligible ? "" : ",blocked=max-size";
                      return `S${candidate.shard_index}(overlap=${candidate.overlap},load=${candidate.feature_load_before},size=${candidate.member_count_before}${blocked})`;
                    })
                    .join(" | ");

                  return (
                    <li
                      key={`step-${step.step}-${step.formula}`}
                      className={`explain-step ${visible ? "is-visible" : "is-pending"}`}
                    >
                      <p>
                        <span className="step-number">#{step.step}</span> {step.formula} {"->"} shard{" "}
                        {step.selected_shard_index}
                      </p>
                      <p>
                        feature_count={step.feature_count}, weight={step.weight}, selected overlap={selected?.overlap ?? 0}
                      </p>
                      {step.capacity_constrained ? (
                        <p className="small-note">
                          capacity constraint active (max_shard_size={step.max_shard_size}){step.forced_by_capacity
                            ? "; higher-overlap shard was full."
                            : "."}
                        </p>
                      ) : null}
                      <p className="small-note">candidates: {candidateText}</p>
                    </li>
                  );
                })}
              </ol>
            </section>
          ) : null}

          {!explanation && result.compatible_dependents_count >= 30 ? (
            <section className="card">
              <h2>Animated Split Explanation</h2>
              <p className="mono impact">
                Disabled because this run has {result.compatible_dependents_count} compatible dependents. The animation is
                only rendered when compatible dependents are below 30.
              </p>
            </section>
          ) : null}

          <section className="card">
            <h2>Shard Distribution</h2>
            <div className="shards">
              {result.shards.map((shard) => {
                const width = maxShardSize ? Math.max((shard.member_count / maxShardSize) * 100, 2) : 0;

                return (
                  <article className="shard" key={shard.shard_index}>
                    <div className="shard-head">
                      <h3>Shard {shard.shard_index}</h3>
                      <span className="pill">{shard.member_count} deps</span>
                    </div>
                    <div className="bar">
                      <span style={{ width: `${width}%` }} />
                    </div>
                    <p className="meta mono">feature load: {shard.feature_load}</p>
                    <ul className="mono list">
                      {shard.members.slice(0, 70).map((name) => (
                        <li key={name}>{name}</li>
                      ))}
                    </ul>
                  </article>
                );
              })}
            </div>
          </section>

          <section className="card split">
            <div>
              <h2>Compatible Dependents ({result.dependents.length})</h2>
              <ul className="mono list tall">
                {result.dependents.map((name) => (
                  <li key={name}>{name}</li>
                ))}
              </ul>
            </div>
            <div>
              <h2>Filtered by Runner Tag ({result.filtered_dependents.length})</h2>
              <ul className="mono list tall">
                {result.filtered_dependents.map((name) => (
                  <li key={name}>{name}</li>
                ))}
              </ul>
            </div>
          </section>
        </>
      ) : null}
    </main>
  );
}

function Metric({ label, value }) {
  return (
    <article className="metric card">
      <p>{label}</p>
      <strong>{value}</strong>
    </article>
  );
}
