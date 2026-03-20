import { cpSync, mkdirSync, existsSync, readdirSync } from "node:fs";
import { join } from "node:path";

const source = join(process.cwd(), ".opencode", "skills");
const dest = join(process.cwd(), ".kilo", "skill");

function copyDir(src: string, dst: string) {
  if (!existsSync(dst)) {
    mkdirSync(dst, { recursive: true });
  }

  const entries = readdirSync(src, { withFileTypes: true });

  for (const entry of entries) {
    const srcPath = join(src, entry.name);
    const dstPath = join(dst, entry.name);

    if (entry.isDirectory()) {
      copyDir(srcPath, dstPath);
    } else {
      cpSync(srcPath, dstPath, { recursive: true });
    }
  }
}

copyDir(source, dest);
console.log("Skills synced from .opencode/skills to .kilo/skill/");
