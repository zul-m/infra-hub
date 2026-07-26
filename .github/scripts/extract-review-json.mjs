import { existsSync, readFileSync, writeFileSync } from "node:fs";

const inputPath = process.argv[2] ?? "copilot-output.txt";
const outputPath = process.argv[3] ?? "review.json";

const ALLOWED_SEVERITIES = new Set(["high", "medium", "low"]);

function parseDirectJson(text) {
  const trimmed = text.trim();
  if (!trimmed) {
    return null;
  }

  try {
    return JSON.parse(trimmed);
  } catch {
    return null;
  }
}

function extractFromCodeFence(text) {
  const fenceMatch = text.match(/```(?:json)?\s*([\s\S]*?)\s*```/i);
  if (!fenceMatch) {
    return null;
  }

  try {
    return JSON.parse(fenceMatch[1]);
  } catch {
    return null;
  }
}

function extractByBalancedBraces(text) {
  const starts = [];

  for (let i = 0; i < text.length; i += 1) {
    if (text[i] === "{") {
      starts.push(i);
    }
  }

  for (const start of starts) {
    let depth = 0;
    let inString = false;
    let escaped = false;

    for (let i = start; i < text.length; i += 1) {
      const ch = text[i];

      if (inString) {
        if (escaped) {
          escaped = false;
          continue;
        }

        if (ch === "\\") {
          escaped = true;
          continue;
        }

        if (ch === '"') {
          inString = false;
        }

        continue;
      }

      if (ch === '"') {
        inString = true;
        continue;
      }

      if (ch === "{") {
        depth += 1;
      } else if (ch === "}") {
        depth -= 1;

        if (depth === 0) {
          const candidate = text.slice(start, i + 1);
          try {
            return JSON.parse(candidate);
          } catch {
            break;
          }
        }
      }
    }
  }

  return null;
}

function isValidReviewPayload(payload) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return false;
  }

  if (typeof payload.summary !== "string") {
    return false;
  }

  if (!Array.isArray(payload.comments)) {
    return false;
  }

  for (const comment of payload.comments) {
    if (!comment || typeof comment !== "object" || Array.isArray(comment)) {
      return false;
    }

    if (typeof comment.path !== "string" || comment.path.trim().length === 0) {
      return false;
    }

    if (!Number.isInteger(comment.line) || comment.line <= 0) {
      return false;
    }

    if (typeof comment.body !== "string" || comment.body.trim().length === 0) {
      return false;
    }

    if (
      comment.severity !== undefined &&
      (typeof comment.severity !== "string" || !ALLOWED_SEVERITIES.has(comment.severity))
    ) {
      return false;
    }
  }

  return true;
}

function parseCandidate(raw) {
  return (
    parseDirectJson(raw) ??
    extractFromCodeFence(raw) ??
    extractByBalancedBraces(raw)
  );
}

function safePreview(text, maxLength = 800) {
  return text.replace(/\s+/g, " ").trim().slice(0, maxLength);
}

const sources = [];

if (existsSync(outputPath)) {
  const raw = readFileSync(outputPath, "utf8");
  if (raw.trim().length > 0) {
    sources.push({ name: outputPath, raw });
  }
}

if (existsSync(inputPath)) {
  const raw = readFileSync(inputPath, "utf8");
  if (raw.trim().length > 0) {
    sources.push({ name: inputPath, raw });
  }
}

if (sources.length === 0) {
  throw new Error(
    `No extraction sources found. Checked ${outputPath} and ${inputPath}.`,
  );
}

let parsed = null;
let parsedFrom = null;

for (const source of sources) {
  const candidate = parseCandidate(source.raw);
  if (isValidReviewPayload(candidate)) {
    parsed = candidate;
    parsedFrom = source.name;
    break;
  }
}

if (!isValidReviewPayload(parsed)) {
  for (const source of sources) {
    const candidate = parseCandidate(source.raw);
    process.stderr.write(`Extraction debug for ${source.name}:\n`);
    process.stderr.write(`- Raw preview: ${safePreview(source.raw)}\n`);
    process.stderr.write(`- Parsed candidate: ${JSON.stringify(candidate, null, 2)}\n`);
    process.stderr.write(`- Valid payload: ${isValidReviewPayload(candidate)}\n`);
  }

  throw new Error(
    "Could not extract a valid review JSON object with summary/comments from Copilot output.",
  );
}

writeFileSync(outputPath, `${JSON.stringify(parsed, null, 2)}\n`, "utf8");
process.stdout.write(
  `Wrote validated review JSON to ${outputPath} (source: ${parsedFrom}).\n`,
);
