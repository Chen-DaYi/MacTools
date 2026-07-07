import { existsSync, mkdirSync, symlinkSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const source = resolve(root, "..", "docs", "assets");
const target = resolve(root, "public", "assets");

if (!existsSync(source)) {
  throw new Error(`Missing shared docs assets at ${source}`);
}

if (!existsSync(target)) {
  mkdirSync(dirname(target), { recursive: true });
  symlinkSync(source, target, "dir");
}
