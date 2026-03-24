#!/usr/bin/env bun
/**
 * Release script: consume changesets → bump version → update CHANGELOG → tag.
 *
 * Usage:
 *   bun run release           # consume changesets, bump, tag
 *   bun run release --dry-run # show what would happen without mutating
 */

import { execSync } from "child_process";
import { readFileSync, writeFileSync } from "fs";

const dry = process.argv.includes("--dry-run");

function run(cmd: string): string {
  if (dry) {
    console.log(`[dry-run] ${cmd}`);
    return "";
  }
  const result = execSync(cmd, { encoding: "utf-8", stdio: "inherit" });
  return typeof result === "string" ? result.trim() : "";
}

function readVersion(): string {
  const content = readFileSync("Sources/HexCLI/Version.swift", "utf-8");
  const match = content.match(/"(\d+\.\d+\.\d+)"/);
  if (!match) throw new Error("Could not read version from Version.swift");
  return match[1];
}

function writeVersion(version: string): void {
  const path = "Sources/HexCLI/Version.swift";
  let content = readFileSync(path, "utf-8");
  content = content.replace(/"(\d+\.\d+\.\d+)"/, `"${version}"`);
  writeFileSync(path, content);
}

// 1. Show pending changesets
console.log("→ Checking changeset status...");
const status = execSync("bunx changeset status --verbose 2>&1", { encoding: "utf-8" });
console.log(status);

if (dry) {
  console.log("[dry-run] Would consume changesets, bump version, update CHANGELOG, commit, and tag.");
  console.log(`[dry-run] Current version: ${readVersion()}`);
  process.exit(0);
}

// 2. Consume changesets (bumps package.json version + updates CHANGELOG.md)
console.log("→ Consuming changesets...");
execSync("bunx changeset version", { stdio: "inherit" });

// 3. Read the new version from package.json
const pkg = JSON.parse(readFileSync("package.json", "utf-8"));
const newVersion = pkg.version;
console.log(`→ New version: ${newVersion}`);

// 4. Sync version to Version.swift
console.log("→ Syncing version to Version.swift...");
writeVersion(newVersion);

// 5. Stage, commit, tag
console.log("→ Committing release...");
run("git add Sources/HexCLI/Version.swift package.json CHANGELOG.md .changeset/");
run(`git commit -m "Release ${newVersion}"`);
run(`git tag -a "v${newVersion}" -m "v${newVersion}"`);

console.log(`\n✓ Release v${newVersion} ready.`);
console.log(`  Push with: git push origin main --tags`);
