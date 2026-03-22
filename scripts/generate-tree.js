import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ROOT_DIR = path.join(__dirname);
const OUTPUT_FILE = path.join(__dirname, 'docs', 'tree.md');

const IGNORE_DIRS = ['node_modules', '.git', 'snapshots', 'temp', '.vscode', 'wallpaper', 'docs', '.codex', '.github'];
const IGNORE_EXTENSIONS = ['.tsbuildinfo'];
const MAX_DEPTH = 3;

function generateTree(dir, prefix = '', depth = 0) {
    const items = [];

    try {
        const entries = fs.readdirSync(dir, { withFileTypes: true });

        entries.sort((a, b) => {
            if (a.isDirectory() && !b.isDirectory()) return -1;
            if (!a.isDirectory() && b.isDirectory()) return 1;
            return a.name.localeCompare(b.name);
        });

        entries.forEach((entry, index) => {
            if (IGNORE_DIRS.includes(entry.name)) return;

            const fullPath = path.join(dir, entry.name);
            const relativePath = path.relative(ROOT_DIR, fullPath);
            const isLastItem = index === entries.length - 1;

            if (!entry.isDirectory()) {
                const ext = path.extname(entry.name);
                if (IGNORE_EXTENSIONS.includes(ext)) return;
            }

            const connector = isLastItem ? '└── ' : '├── ';
            const filePath = relativePath.replace(/\\/g, '/');

            const ext = path.extname(entry.name);
            const isCodeFile = ['.ps1', '.js', '.css', '.html', '.json', '.md'].includes(ext);

            if (isCodeFile) {
                items.push(`${prefix}${connector}[${entry.name}](${filePath})`);
            } else {
                items.push(`${prefix}${connector}${entry.name}`);
            }

            if (entry.isDirectory() && depth < MAX_DEPTH) {
                const newPrefix = prefix + (isLastItem ? '    ' : '│   ');
                const childItems = generateTree(fullPath, newPrefix, depth + 1);
                items.push(...childItems);
            }
        });
    } catch (error) {
        return items;
    }

    return items;
}

const treeLines = ['# Project Tree', '', 'Click filename to view source.', '', '```', ''];

const srcTree = generateTree(ROOT_DIR);
treeLines.push(...srcTree);

treeLines.push('', '```');

if (!fs.existsSync(path.join(__dirname, 'docs'))) {
    fs.mkdirSync(path.join(__dirname, 'docs'), { recursive: true });
}

fs.writeFileSync(OUTPUT_FILE, treeLines.join('\n'), 'utf8');

console.log('docs/tree.md');
