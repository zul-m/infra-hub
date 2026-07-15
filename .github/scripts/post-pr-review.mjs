import { readFileSync, writeFileSync } from "node:fs";

const token = process.env.GITHUB_TOKEN;
const repository = process.env.GITHUB_REPOSITORY;
const apiUrl = process.env.GITHUB_API_URL ?? "https://api.github.com";
const eventPath = process.env.GITHUB_EVENT_PATH;

if (!token) {
  throw new Error("GITHUB_TOKEN is required");
}

if (!repository) {
  throw new Error("GITHUB_REPOSITORY is required");
}

if (!eventPath) {
  throw new Error("GITHUB_EVENT_PATH is required");
}

const event = JSON.parse(readFileSync(eventPath, "utf8"));
const pullRequest = event.pull_request;

if (!pullRequest?.number) {
  throw new Error("This workflow expects a pull_request event payload");
}

const [owner, repo] = repository.split("/");
const context = JSON.parse(readFileSync("pr-context.json", "utf8"));
const review = JSON.parse(readFileSync("review.json", "utf8"));

function normalizeBody(body, severity) {
  const prefix = severity ? `**${severity.toUpperCase()}**\n\n` : "";
  return `${prefix}${body}`.trim();
}

function getAllowedLinesByPath(files) {
  return new Map(files.map((file) => [file.path, new Set(file.added_lines)]));
}

function uniqueBy(items, getKey) {
  const seen = new Set();
  return items.filter((item) => {
    const key = getKey(item);
    if (seen.has(key)) {
      return false;
    }
    seen.add(key);
    return true;
  });
}

async function githubRequest(path, init = {}) {
  const response = await fetch(`${apiUrl}${path}`, {
    ...init,
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "X-GitHub-Api-Version": "2026-03-10",
      ...(init.headers ?? {}),
    },
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`GitHub API ${path} failed: ${response.status} ${body}`);
  }

  if (response.status === 204) {
    return null;
  }

  return response.json();
}

async function getExistingComments() {
  return githubRequest(
    `/repos/${owner}/${repo}/pulls/${pullRequest.number}/comments?per_page=100`,
  );
}

const summary = typeof review.summary === "string" ? review.summary.trim() : "";
const requestedComments = Array.isArray(review.comments) ? review.comments : [];
const allowedLinesByPath = getAllowedLinesByPath(context.files ?? []);
const existingComments = await getExistingComments();

const existingKeys = new Set(
  existingComments
    .filter((comment) => comment.user?.login === "github-actions[bot]")
    .map((comment) => `${comment.path}:${comment.line}:${comment.body}`),
);

const filteredComments = uniqueBy(
  requestedComments
    .filter((comment) => typeof comment?.path === "string")
    .filter((comment) => Number.isInteger(comment?.line) && comment.line > 0)
    .filter((comment) => typeof comment?.body === "string" && comment.body.trim().length > 0)
    .filter((comment) => allowedLinesByPath.get(comment.path)?.has(comment.line))
    .map((comment) => ({
      path: comment.path,
      line: comment.line,
      body: normalizeBody(comment.body.trim(), comment.severity),
    }))
    .filter((comment) => !existingKeys.has(`${comment.path}:${comment.line}:${comment.body}`)),
  (comment) => `${comment.path}:${comment.line}:${comment.body}`,
).slice(0, 8);

const summaryLines = [
  "# Copilot PR Review",
  "",
  summary || "No summary returned.",
  "",
  `New inline comments posted: ${filteredComments.length}`,
];

writeFileSync("review-summary.md", `${summaryLines.join("\n")}\n`, "utf8");

if (filteredComments.length === 0) {
  process.stdout.write("No new inline review comments to post.\n");
  process.exit(0);
}

await githubRequest(`/repos/${owner}/${repo}/pulls/${pullRequest.number}/reviews`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
  },
  body: JSON.stringify({
    commit_id: pullRequest.head.sha,
    body: summary || "Automated Copilot review findings.",
    event: "COMMENT",
    comments: filteredComments.map((comment) => ({
      path: comment.path,
      line: comment.line,
      side: "RIGHT",
      body: comment.body,
    })),
  }),
});

process.stdout.write(`Posted ${filteredComments.length} inline review comment(s).\n`);