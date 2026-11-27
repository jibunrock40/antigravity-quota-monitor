/**
 * Portable launcher for the Antigravity desktop floating quota widget.
 *
 * - Windows: locates a Python installation with PyQt5 and runs `quota_floating_widget.pyw`.
 * - macOS: locates `swiftc` (Xcode Command Line Tools), compiles & caches the native
 *   AppKit/WKWebView floating widget (`QuotaFloatingWidget.swift`), and runs it.
 * - Exits cleanly (code 0) on unsupported platforms or when prerequisites are missing
 *   so the right-sidebar panel remains unaffected.
 */
import { createHash } from 'node:crypto';
import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const pluginDirName = basename(resolve(__dirname, '..', '..')) || 'quota-monitor';
const widgetScript = resolve(__dirname, '..', '..', 'widget', 'quota_floating_widget.pyw');
const macSource = resolve(__dirname, '..', '..', 'widget', 'macos', 'QuotaFloatingWidget.swift');
const macHtml = resolve(__dirname, '..', '..', 'widget', 'macos', 'widget.html');
const args = new Set(process.argv.slice(2));
const isDryRun = args.has('--dry-run');
const isDetached = args.has('--detached');

function isRealExecutable(filePath) {
  try {
    if (!filePath || !existsSync(filePath)) return false;
    // Skip Microsoft Store zero-byte app execution aliases if they aren't usable.
    if (/\\Microsoft\\WindowsApps\\/i.test(filePath)) return false;
    return statSync(filePath).isFile();
  } catch {
    return false;
  }
}

function whereExe(name) {
  try {
    const out = execFileSync('where.exe', [name], {
      encoding: 'utf-8',
      windowsHide: true,
      timeout: 3000,
    });
    return out
      .split(/\r?\n/)
      .map((l) => l.trim())
      .filter(Boolean);
  } catch {
    return [];
  }
}

function collectPythonCandidates() {
  const candidates = [];
  const seen = new Set();
  const push = (p) => {
    if (!p) return;
    const norm = resolve(p);
    const key = norm.toLowerCase();
    if (!seen.has(key) && isRealExecutable(norm)) {
      seen.add(key);
      candidates.push(norm);
    }
  };

  // 1. Explicit user override
  if (process.env.ANTIGRAVITY_QUOTA_PYTHON) {
    push(process.env.ANTIGRAVITY_QUOTA_PYTHON);
  }

  // 2. Active PATH lookups
  for (const exe of whereExe('pythonw')) push(exe);
  for (const exe of whereExe('python')) push(exe);

  // 3. Common user/system Python & Conda installation directories (dynamic)
  const home = homedir();
  const localAppData = process.env.LOCALAPPDATA || join(home, 'AppData', 'Local');
  const userProfile = process.env.USERPROFILE || home;
  const programData = process.env.ProgramData || 'C:\\ProgramData';
  const programFiles = process.env.ProgramFiles || 'C:\\Program Files';

  const baseRoots = [
    join(userProfile, 'anaconda3'),
    join(userProfile, 'miniconda3'),
    join(userProfile, 'miniforge3'),
    join(userProfile, 'mambaforge'),
    join(localAppData, 'anaconda3'),
    join(localAppData, 'miniconda3'),
    join(programData, 'anaconda3'),
    join(programData, 'miniconda3'),
  ];

  for (const root of baseRoots) {
    push(join(root, 'pythonw.exe'));
    push(join(root, 'python.exe'));
    const envsDir = join(root, 'envs');
    try {
      if (existsSync(envsDir)) {
        for (const ent of readdirSync(envsDir, { withFileTypes: true })) {
          if (ent.isDirectory()) {
            push(join(envsDir, ent.name, 'pythonw.exe'));
            push(join(envsDir, ent.name, 'python.exe'));
          }
        }
      }
    } catch {
      // Ignore unreadable directories.
    }
  }

  const pythonRoots = [
    join(localAppData, 'Programs', 'Python'),
    programFiles,
    'C:\\',
  ];
  for (const parent of pythonRoots) {
    try {
      if (!existsSync(parent)) continue;
      for (const ent of readdirSync(parent, { withFileTypes: true })) {
        if (ent.isDirectory() && /^Python3\d+$/i.test(ent.name)) {
          push(join(parent, ent.name, 'pythonw.exe'));
          push(join(parent, ent.name, 'python.exe'));
        }
      }
    } catch {
      // Ignore unreadable directories.
    }
  }

  return candidates;
}

function toProbeAndGuiPair(candidate) {
  const dir = dirname(candidate);
  const siblingPython = join(dir, 'python.exe');
  const siblingPythonw = join(dir, 'pythonw.exe');
  const probeExe = isRealExecutable(siblingPython) ? siblingPython : candidate;
  const guiExe = isRealExecutable(siblingPythonw) ? siblingPythonw : candidate;
  return { probeExe, guiExe };
}

function hasPyQt5(probeExe) {
  try {
    execFileSync(probeExe, ['-c', 'import PyQt5.QtWidgets'], {
      stdio: 'ignore',
      windowsHide: true,
      timeout: 5000,
    });
    return true;
  } catch {
    return false;
  }
}

function findPyQt5Python() {
  const testedProbes = new Set();
  for (const candidate of collectPythonCandidates()) {
    const { probeExe, guiExe } = toProbeAndGuiPair(candidate);
    const key = probeExe.toLowerCase();
    if (testedProbes.has(key)) continue;
    testedProbes.add(key);
    if (hasPyQt5(probeExe)) {
      return guiExe;
    }
  }
  return null;
}

function findSwiftc() {
  const candidates = [];
  if (process.env.ANTIGRAVITY_QUOTA_SWIFTC) {
    candidates.push(process.env.ANTIGRAVITY_QUOTA_SWIFTC);
  }
  candidates.push('/usr/bin/swiftc');
  try {
    const found = execFileSync('xcrun', ['-f', 'swiftc'], {
      encoding: 'utf-8',
      timeout: 3000,
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    if (found) candidates.push(found);
  } catch {
    // Ignore xcrun lookup errors.
  }

  const seen = new Set();
  for (const cand of candidates) {
    if (!cand) continue;
    const norm = resolve(cand);
    if (seen.has(norm)) continue;
    seen.add(norm);
    try {
      if (!existsSync(norm) || !statSync(norm).isFile()) continue;
      execFileSync(norm, ['--version'], { stdio: 'ignore', timeout: 5000 });
      return norm;
    } catch {
      // Unconfigured shim or unusable compiler.
    }
  }
  return null;
}

function findMacSdkPath() {
  if (process.env.SDKROOT && existsSync(process.env.SDKROOT)) {
    return process.env.SDKROOT;
  }
  try {
    const sdk = execFileSync('xcrun', ['--show-sdk-path'], {
      encoding: 'utf-8',
      timeout: 3000,
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    if (sdk && existsSync(sdk)) return sdk;
  } catch {
    // Ignore xcrun sdk lookup errors.
  }
  const cltSdk = '/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk';
  return existsSync(cltSdk) ? cltSdk : null;
}

function getMacBuildPaths() {
  const baseDir = process.env.ANTIGRAVITY_EXECUTABLE_DATA_DIR
    ? resolve(process.env.ANTIGRAVITY_EXECUTABLE_DATA_DIR, '..')
    : join(homedir(), '.gemini', 'antigravity', 'sidecar_data', pluginDirName, 'quota_floating');
  const binDir = join(baseDir, 'bin');
  return {
    binDir,
    binaryPath: join(binDir, 'quota-floating-widget'),
    metaPath: join(binDir, 'quota-floating-widget.build-meta.json'),
  };
}

function computeMacSourceDigest() {
  const srcBytes = readFileSync(macSource);
  return createHash('sha256')
    .update(srcBytes)
    .update(`\0arch=${process.arch}\0`)
    .digest('hex');
}

function needsMacBuild(binaryPath, metaPath, digest) {
  if (!existsSync(binaryPath) || !existsSync(metaPath)) return true;
  try {
    const meta = JSON.parse(readFileSync(metaPath, 'utf-8'));
    return meta?.digest !== digest || meta?.arch !== process.arch;
  } catch {
    return true;
  }
}

function ensureMacBinary(swiftcExe) {
  const { binDir, binaryPath, metaPath } = getMacBuildPaths();
  const digest = computeMacSourceDigest();
  if (!needsMacBuild(binaryPath, metaPath, digest)) {
    return binaryPath;
  }
  mkdirSync(binDir, { recursive: true });
  const sdkPath = findMacSdkPath();
  const swiftArgs = [
    '-O',
    ...(sdkPath ? ['-sdk', sdkPath] : []),
    '-framework', 'Cocoa',
    '-framework', 'WebKit',
    '-framework', 'CoreGraphics',
    macSource,
    '-o', binaryPath,
  ];
  execFileSync(
    swiftcExe,
    swiftArgs,
    {
      stdio: 'inherit',
      timeout: 120_000,
    },
  );
  writeFileSync(
    metaPath,
    JSON.stringify({ digest, arch: process.arch, builtAt: Date.now() }, null, 2),
    'utf-8',
  );
  return binaryPath;
}

function spawnManaged(exe, spawnArgs, windowsHide = false) {
  if (isDetached) {
    const child = spawn(exe, spawnArgs, {
      detached: true,
      stdio: 'ignore',
      windowsHide,
    });
    child.unref();
    process.exit(0);
  }

  const child = spawn(exe, spawnArgs, {
    stdio: 'inherit',
    windowsHide,
  });

  for (const sig of ['SIGINT', 'SIGTERM']) {
    process.on(sig, () => {
      try {
        child.kill(sig);
      } catch {
        // Ignore if already exited.
      }
    });
  }

  child.on('error', (err) => {
    console.error(`[quota_floating] Failed to launch widget: ${err?.message || err}`);
    process.exit(1);
  });

  child.on('exit', (code) => {
    process.exit(typeof code === 'number' ? code : 0);
  });
}

if (process.platform === 'darwin') {
  const sourceExists = existsSync(macSource);
  const htmlExists = existsSync(macHtml);
  const swiftcExe = findSwiftc();
  const { binaryPath, metaPath } = getMacBuildPaths();
  const needsBuild = sourceExists ? needsMacBuild(binaryPath, metaPath, computeMacSourceDigest()) : true;

  if (isDryRun) {
    const ok = Boolean(sourceExists && htmlExists && (swiftcExe || !needsBuild));
    console.log(JSON.stringify({
      ok,
      platform: process.platform,
      arch: process.arch,
      swiftcExe,
      sourcePath: macSource,
      sourceExists,
      htmlPath: macHtml,
      htmlExists,
      binaryPath,
      needsBuild,
    }, null, 2));
    process.exit(ok ? 0 : 1);
  }

  if (!sourceExists || !htmlExists) {
    console.error(`[quota_floating] macOS widget files not found: ${macSource}`);
    process.exit(0);
  }

  if (needsBuild && !swiftcExe) {
    console.log(
      '[quota_floating] Swift compiler (swiftc) not found. Install Xcode Command Line Tools ' +
      '(`xcode-select --install`) to enable the macOS floating desktop widget.',
    );
    process.exit(0);
  }

  let builtBinary = binaryPath;
  try {
    if (needsBuild) {
      builtBinary = ensureMacBinary(swiftcExe);
    }
  } catch (err) {
    console.error(`[quota_floating] Failed to compile macOS widget: ${err?.message || err}`);
    process.exit(0);
  }

  const macArgs = ['--html', macHtml, '--plugin-dir', pluginDirName];
  if (isDetached) {
    macArgs.push('--detached');
  }
  spawnManaged(builtBinary, macArgs, false);
} else if (process.platform !== 'win32') {
  const msg = `[quota_floating] Floating desktop widget is supported on Windows and macOS (current platform: ${process.platform}); right-sidebar panel remains active.`;
  if (isDryRun) {
    console.log(JSON.stringify({
      ok: true,
      platform: process.platform,
      pythonExe: null,
      widgetScript,
      widgetExists: existsSync(widgetScript),
      note: msg,
    }, null, 2));
  } else {
    console.log(msg);
  }
  process.exit(0);
} else {
  const widgetExists = existsSync(widgetScript);
  const pythonExe = findPyQt5Python();

  if (isDryRun) {
    const ok = Boolean(pythonExe && widgetExists);
    console.log(JSON.stringify({
      ok,
      platform: process.platform,
      pythonExe,
      widgetScript,
      widgetExists,
    }, null, 2));
    process.exit(ok ? 0 : 1);
  }

  if (!widgetExists) {
    console.error(`[quota_floating] Widget script not found: ${widgetScript}`);
    process.exit(0);
  }

  if (!pythonExe) {
    console.log(
      '[quota_floating] Python with PyQt5 not found. Install PyQt5 (e.g. `pip install PyQt5`) ' +
      'or set ANTIGRAVITY_QUOTA_PYTHON to enable the floating desktop widget.',
    );
    process.exit(0);
  }

  spawnManaged(pythonExe, [widgetScript], true);
}
