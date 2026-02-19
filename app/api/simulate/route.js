import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";

const execFileAsync = promisify(execFile);

export async function POST(request) {
  let body;
  try {
    body = await request.json();
  } catch {
    return Response.json({ error: "Invalid JSON body." }, { status: 400 });
  }

  const args = [
    `--formula=${body.formula || "openssl@3"}`,
    `--max-runners=${Math.max(Number(body.maxRunners || 4), 1)}`,
    `--min-per-runner=${Math.max(Number(body.minPerRunner || 200), 1)}`,
    `--recursive=${body.recursive !== false}`,
    `--include-build=${body.includeBuild !== false}`,
    `--include-test=${body.includeTest !== false}`,
    `--runner-tag=${body.runnerTag || "x86_64_linux"}`,
    `--core-compat=${body.coreCompat === true}`,
  ];

  const scriptPath = path.join(process.cwd(), "scripts", "simulate_sharding.rb");

  try {
    const { stdout, stderr } = await execFileAsync("ruby", [scriptPath, ...args], {
      timeout: 240000,
      maxBuffer: 8 * 1024 * 1024,
    });

    if (stderr && stderr.trim()) {
      return Response.json({ error: stderr.trim() }, { status: 500 });
    }

    const payload = JSON.parse(stdout);
    if (payload.error) {
      return Response.json(payload, { status: 400 });
    }

    return Response.json(payload);
  } catch (error) {
    const message = error?.stderr?.toString()?.trim() || error?.message || "Simulation failed.";
    return Response.json({ error: message }, { status: 500 });
  }
}
