import { readFileSync, writeFileSync } from "node:fs";

const inputPath = process.argv[2] ?? "copilot-output.txt";
const outputPath = process.argv[3] ?? "review.json";

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

  return true;
}

const raw = readFileSync(inputPath, "utf8");

const parsed =
  parseDirectJson(raw) ??
  extractFromCodeFence(raw) ??
  extractByBalancedBraces(raw);

if (!isValidReviewPayload(parsed)) {
  throw new Error(
    "Could not extract a valid review JSON object with summary/comments from Copilot output.",
  );
}

writeFileSync(outputPath, `${JSON.stringify(parsed, null, 2)}\n`, "utf8");
process.stdout.write(`Wrote validated review JSON to ${outputPath}.\n`);
