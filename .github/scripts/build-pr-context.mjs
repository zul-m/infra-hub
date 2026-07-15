import { readFileSync } from "node:fs";

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

function parseAddedLines(patch) {
  const addedLines = [];
  let newLine = 0;

  for (const line of patch.split("\n")) {
    const header = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/);

    if (header) {
      newLine = Number.parseInt(header[1], 10);
      continue;
    }

    if (!newLine) {
      continue;
    }

    if (line.startsWith("+") && !line.startsWith("+++")) {
      addedLines.push(newLine);
      newLine += 1;
      continue;
    }

    if (line.startsWith(" ")) {
      newLine += 1;
      continue;
    }

    if (line.startsWith("-") && !line.startsWith("---")) {
      continue;
    }
  }

  return addedLines;
}

async function githubRequest(path) {
  const response = await fetch(`${apiUrl}${path}`, {
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "X-GitHub-Api-Version": "2026-03-10",
    },
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`GitHub API ${path} failed: ${response.status} ${body}`);
  }

  return response.json();
}

async function getPullRequestFiles() {
  const files = [];

  for (let page = 1; page < 11; page += 1) {
    const batch = await githubRequest(
      `/repos/${owner}/${repo}/pulls/${pullRequest.number}/files?per_page=100&page=${page}`,
    );

    files.push(...batch);

    if (batch.length < 100) {
      break;
    }
  }

  return files;
}

const files = await getPullRequestFiles();

const context = {
  repository,
  pull_request: {
    number: pullRequest.number,
    title: pullRequest.title,
    body: pullRequest.body,
    base_ref: pullRequest.base.ref,
    head_ref: pullRequest.head.ref,
    base_sha: pullRequest.base.sha,
    head_sha: pullRequest.head.sha,
  },
  files: files
    .filter((file) => typeof file.patch === "string" && file.patch.length > 0)
    .map((file) => ({
      path: file.filename,
      status: file.status,
      additions: file.additions,
      deletions: file.deletions,
      changes: file.changes,
      added_lines: parseAddedLines(file.patch),
      patch: file.patch,
    })),
};

process.stdout.write(`${JSON.stringify(context, null, 2)}\n`);