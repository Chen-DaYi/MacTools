const root = document.documentElement;
const storedTheme = localStorage.getItem("mactools-theme");
const storedLang = localStorage.getItem("mactools-lang");
const applyLanguage = (lang: "zh" | "en") => {
  root.dataset.lang = lang;
  root.lang = lang === "zh" ? "zh-CN" : "en";
};

if (storedTheme === "dark" || storedTheme === "light") {
  root.dataset.theme = storedTheme;
} else if (window.matchMedia("(prefers-color-scheme: dark)").matches) {
  root.dataset.theme = "dark";
}

if (storedLang === "zh" || storedLang === "en") {
  applyLanguage(storedLang);
} else {
  const browserLanguages = navigator.languages?.length ? navigator.languages : [navigator.language];
  const prefersChinese = browserLanguages.some((language) => language.toLowerCase().startsWith("zh"));
  applyLanguage(prefersChinese ? "zh" : "en");
}

document.querySelectorAll<HTMLElement>("[data-copy]").forEach((button) => {
  const initialText = button.textContent ?? "复制";
  button.addEventListener("click", async () => {
    const value = button.dataset.copy;
    if (!value) return;

    try {
      await navigator.clipboard.writeText(value);
      button.textContent = root.dataset.lang === "en" ? "Copied" : "已复制";
      window.setTimeout(() => {
        button.textContent = initialText;
      }, 1600);
    } catch {
      button.textContent = value;
    }
  });
});

document.querySelector<HTMLElement>("[data-theme-toggle]")?.addEventListener("click", () => {
  const next = root.dataset.theme === "dark" ? "light" : "dark";
  root.dataset.theme = next;
  localStorage.setItem("mactools-theme", next);
});

document.querySelector<HTMLElement>("[data-language-toggle]")?.addEventListener("click", () => {
  const next = root.dataset.lang === "en" ? "zh" : "en";
  applyLanguage(next);
  localStorage.setItem("mactools-lang", next);
});

const pluginFilterButtons = [...document.querySelectorAll<HTMLButtonElement>("[data-plugin-filter]")];
const pluginCards = [...document.querySelectorAll<HTMLElement>("[data-plugin-category]")];

if (pluginFilterButtons.length && pluginCards.length) {
  const availableFilters = new Set(pluginFilterButtons.map((button) => button.dataset.pluginFilter));

  const applyPluginFilter = (filter: string) => {
    const selectedFilter = availableFilters.has(filter) ? filter : "all";

    for (const button of pluginFilterButtons) {
      button.setAttribute("aria-pressed", String(button.dataset.pluginFilter === selectedFilter));
    }

    for (const card of pluginCards) {
      const isVisible = selectedFilter === "all" || card.dataset.pluginCategory === selectedFilter;
      card.hidden = !isVisible;
    }
  };

  for (const button of pluginFilterButtons) {
    button.addEventListener("click", () => {
      const filter = button.dataset.pluginFilter ?? "all";
      applyPluginFilter(filter);

      if (filter === "all") {
        history.replaceState(null, "", `${location.pathname}${location.search}`);
      } else {
        history.replaceState(null, "", `#${filter}`);
      }
    });
  }

  applyPluginFilter(location.hash.replace(/^#/, "") || "all");
  window.addEventListener("hashchange", () => {
    applyPluginFilter(location.hash.replace(/^#/, "") || "all");
  });
}
