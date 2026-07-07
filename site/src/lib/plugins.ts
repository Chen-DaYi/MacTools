import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

export type PluginCatalog = {
  generatedAt: string;
  minimumHostVersion: string;
  plugins: Plugin[];
};

export type Plugin = {
  id: string;
  displayName: string;
  summary: string;
  localizedMetadata?: Record<string, PluginLocalizedMetadata | undefined> | null;
  version: string;
  category: string | null;
  releaseChannel?: string | null;
  releaseNotesURL?: string;
  package?: {
    url: string;
    size: number;
  };
  capabilities: {
    primaryPanel: boolean;
    componentPanel: boolean;
    configuration: boolean;
  };
};

export type PluginLocalizedMetadata = {
  displayName?: string | null;
  summary?: string | null;
};

export type PluginLocalizedText = {
  displayName: string;
  summary: string;
};

const remoteCatalogURL = "https://mactools.ggbond.app/plugins/catalog.json";
const localCatalogPath = resolve(process.cwd(), "..", "docs", "plugins", "catalog.json");

export async function loadPluginCatalog(): Promise<PluginCatalog> {
  try {
    const response = await fetch(remoteCatalogURL);
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    return await response.json() as PluginCatalog;
  } catch {
    const content = await readFile(localCatalogPath, "utf-8");
    return JSON.parse(content) as PluginCatalog;
  }
}

export function categoryLabel(category: string | null): { zh: string; en: string } {
  switch (category) {
    case "display":
      return { zh: "显示与桌面", en: "Display" };
    case "productivity":
      return { zh: "效率", en: "Productivity" };
    case "monitoring":
      return { zh: "监控", en: "Monitoring" };
    case "storage":
      return { zh: "清理与存储", en: "Storage" };
    case "system":
      return { zh: "系统", en: "System" };
    case "audio":
      return { zh: "音频", en: "Audio" };
    default:
      return { zh: "其他", en: "Other" };
  }
}

export function localizedPluginText(plugin: Plugin): { zh: PluginLocalizedText; en: PluginLocalizedText } {
  return {
    zh: textForLocale(plugin, ["zh-Hans", "zh-CN", "zh", "zh-Hant", "zh-TW"]),
    en: textForLocale(plugin, ["en", "en-US", "en-GB"]),
  };
}

function textForLocale(plugin: Plugin, localeCandidates: string[]): PluginLocalizedText {
  const metadata = pickLocalizedMetadata(plugin.localizedMetadata, localeCandidates);
  return {
    displayName: nonEmpty(metadata?.displayName) ?? plugin.displayName,
    summary: nonEmpty(metadata?.summary) ?? plugin.summary,
  };
}

function pickLocalizedMetadata(
  localizedMetadata: Plugin["localizedMetadata"],
  localeCandidates: string[],
): PluginLocalizedMetadata | undefined {
  if (!localizedMetadata) return undefined;

  for (const locale of localeCandidates) {
    const metadata = localizedMetadata[locale];
    if (metadata) return metadata;
  }

  return undefined;
}

function nonEmpty(value?: string | null): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

export function formatSize(size?: number): string {
  if (!size) return "";
  if (size < 1024 * 1024) return `${Math.round(size / 1024)} KB`;
  return `${(size / 1024 / 1024).toFixed(1)} MB`;
}
