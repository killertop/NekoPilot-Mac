const projectRoot = new URL("../", import.meta.url);
const uiRoots = ["src/components", "src/page"];
const standaloneUiFiles = ["src/App.tsx", "src/tray.tsx"];
const excluded = new Set(["src/page/home.css"]);

const forbiddenColors = [
  /#[0-9a-f]{3,8}\b/i,
  /\brgba?\s*\(\s*[\d.]/i,
  /\bhsla?\s*\(\s*[\d.]/i,
];
const forbiddenColorUtilities =
  /\b(?:bg-white|bg-black|text-white|text-black)\b/;
const rawModalOverlay =
  /\bfixed\b[\s\S]{0,240}\binset-0\b|\binset-0\b[\s\S]{0,240}\bfixed\b/;

async function collectFiles(relativeDirectory: string): Promise<string[]> {
  const files: string[] = [];
  for await (
    const entry of Deno.readDir(new URL(`${relativeDirectory}/`, projectRoot))
  ) {
    const relativePath = `${relativeDirectory}/${entry.name}`;
    if (entry.isDirectory) files.push(...await collectFiles(relativePath));
    else if (/\.(?:tsx|css)$/.test(entry.name)) files.push(relativePath);
  }
  return files;
}

const errors: string[] = [];
const allUiFiles = [
  ...(await Promise.all(uiRoots.map(collectFiles))).flat(),
  ...standaloneUiFiles,
];
for (const file of allUiFiles) {
  const source = await Deno.readTextFile(new URL(file, projectRoot));

  // Optical gradients in Home are intentionally exempt from the color-token
  // rule, but structural checks still apply to every stylesheet.
  if (/\.css$/.test(file) && /:root\[data-theme=["']dark["']\]/.test(source)) {
    errors.push(`${file}: explicit dark theme branch is no longer supported`);
  }

  if (
    file !== "src/components/common/app-dialog.tsx" &&
    /\.tsx$/.test(file)
  ) {
    const overlayMatch = rawModalOverlay.exec(source);
    if (overlayMatch) {
      const line = source.slice(0, overlayMatch.index).split("\n").length;
      errors.push(`${file}:${line}: use AppDialog for modal overlays`);
    }
  }

  if (!excluded.has(file)) {
    const lines = source.split("\n");
    lines.forEach((line, index) => {
      if (forbiddenColors.some((pattern) => pattern.test(line))) {
        errors.push(`${file}:${index + 1}: use a semantic --onebox-* token`);
      }
      if (
        /(?:bg|text|border|ring|shadow)-(?:red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose|slate|gray|zinc|neutral|stone)-\d/
          .test(
            line,
          )
      ) {
        errors.push(
          `${file}:${index + 1}: use a semantic --onebox-* token class`,
        );
      }
      if (forbiddenColorUtilities.test(line)) {
        errors.push(
          `${file}:${index + 1}: use a semantic --onebox-* token class`,
        );
      }
    });
  }
}

const appCss = await Deno.readTextFile(new URL("src/App.css", projectRoot));
const themeStart = appCss.indexOf("Theme tokens.");
const lightMatch = appCss.slice(themeStart).match(/:root\s*\{([\s\S]*?)\}/);
const darkMatch = appCss.match(
  /@media\s*\(prefers-color-scheme:\s*dark\)[\s\S]*?:root\[data-theme="system"\]\s*\{([\s\S]*?)\}/,
);

function tokenNames(block: string | undefined): string[] {
  return [...(block ?? "").matchAll(/(--onebox-[\w-]+)\s*:/g)]
    .map((match) => match[1])
    .sort();
}

if (!lightMatch || !darkMatch) {
  errors.push("src/App.css: theme token blocks could not be parsed");
} else {
  const light = tokenNames(lightMatch[1]);
  const dark = tokenNames(darkMatch[1]);
  const missingInDark = light.filter((token) => !dark.includes(token));
  const missingInLight = dark.filter((token) => !light.includes(token));
  if (missingInDark.length) {
    errors.push(
      `src/App.css: missing dark tokens: ${missingInDark.join(", ")}`,
    );
  }
  if (missingInLight.length) {
    errors.push(
      `src/App.css: missing light tokens: ${missingInLight.join(", ")}`,
    );
  }
}

if (errors.length > 0) {
  console.error(errors.join("\n"));
  Deno.exit(1);
}

console.log("[check-ui-style] OK");
