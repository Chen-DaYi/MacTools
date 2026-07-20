export {};

const root = document.documentElement;

type SimulatorLanguage = "zh" | "en";

const currentLanguage = (): SimulatorLanguage => root.dataset.lang === "en" ? "en" : "zh";
const localized = (zh: string, en: string) => currentLanguage() === "en" ? en : zh;
const randomBetween = (minimum: number, maximum: number) =>
  minimum + Math.random() * (maximum - minimum);
const clamp = (value: number, minimum: number, maximum: number) =>
  Math.min(Math.max(value, minimum), maximum);
const lunarDayLabels = [
  "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
  "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
  "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
];

document.querySelectorAll<HTMLElement>("[data-menubar-simulator]").forEach((simulator) => {
  const toast = simulator.querySelector<HTMLElement>("[data-sim-toast]");
  const tabs = [...simulator.querySelectorAll<HTMLButtonElement>("[data-sim-tab]")];
  const views = [...simulator.querySelectorAll<HTMLElement>("[data-sim-view]")];
  let toastTimer: number | undefined;
  let cpu = 24;
  let gpu = 18;
  let memory = 72;
  let battery = 84;
  let activityDayOffset = 0;
  let calendarMonthOffset = 0;

  const updateLocalizedAttributes = () => {
    const language = currentLanguage();

    simulator.querySelectorAll<HTMLElement>("[data-aria-zh][data-aria-en]").forEach((element) => {
      const value = language === "en" ? element.dataset.ariaEn : element.dataset.ariaZh;
      if (value) element.setAttribute("aria-label", value);
    });

    simulator.querySelectorAll<HTMLElement>("[data-title-zh][data-title-en]").forEach((element) => {
      const value = language === "en" ? element.dataset.titleEn : element.dataset.titleZh;
      if (value) element.setAttribute("title", value);
    });
  };

  const selectView = (selectedView: string) => {
    for (const tab of tabs) {
      const isSelected = tab.dataset.simTab === selectedView;
      tab.classList.toggle("is-selected", isSelected);
      tab.setAttribute("aria-selected", String(isSelected));
    }

    for (const view of views) {
      const isSelected = view.dataset.simView === selectedView;
      view.hidden = !isSelected;
      view.classList.toggle("is-visible", isSelected);
      if (isSelected) view.scrollTop = 0;
    }
  };

  const showToast = (message: string) => {
    if (!toast) return;

    window.clearTimeout(toastTimer);
    toast.textContent = message;
    toast.classList.add("is-visible");
    toastTimer = window.setTimeout(() => {
      toast.classList.remove("is-visible");
    }, 1600);
  };

  const updateMetric = (metric: string, value: number, digits = 0) => {
    const card = simulator.querySelector<HTMLElement>(`[data-sim-metric="${metric}"]`);
    const valueElement = card?.querySelector<HTMLElement>("[data-sim-value]");
    if (valueElement) valueElement.textContent = value.toFixed(digits);

    card?.querySelectorAll<HTMLElement>(".sim-spark-bars i").forEach((bar, index, bars) => {
      const wave = Math.sin((Date.now() / 780) + index * 0.72) * 0.16;
      const normalized = clamp((value / 100) + wave + randomBetween(-0.12, 0.12), 0.12, 0.96);
      bar.style.transform = `scaleY(${normalized.toFixed(2)})`;
      bar.style.opacity = String(0.52 + (index / bars.length) * 0.36);
    });
  };

  const updateActivityStats = () => {
    const historicalFactor = Math.max(0.42, 1 + activityDayOffset * 0.09);
    const keys = Math.round((8426 + randomBetween(-120, 180)) * historicalFactor);
    const clicks = Math.round((2184 + randomBetween(-60, 90)) * historicalFactor);
    const scrolls = Math.round((1079 + randomBetween(-40, 65)) * historicalFactor);
    const minutes = Math.round((276 + randomBetween(-8, 12)) * historicalFactor);
    const formatter = new Intl.NumberFormat(currentLanguage() === "en" ? "en-US" : "zh-CN");

    const keysElement = simulator.querySelector<HTMLElement>("[data-sim-activity-keys]");
    const clicksElement = simulator.querySelector<HTMLElement>("[data-sim-activity-clicks]");
    const scrollsElement = simulator.querySelector<HTMLElement>("[data-sim-activity-scrolls]");
    const timeElement = simulator.querySelector<HTMLElement>("[data-sim-activity-time]");
    if (keysElement) keysElement.textContent = formatter.format(keys);
    if (clicksElement) clicksElement.textContent = formatter.format(clicks);
    if (scrollsElement) scrollsElement.textContent = formatter.format(scrolls);
    if (timeElement) {
      const hours = Math.floor(minutes / 60);
      const remainingMinutes = minutes % 60;
      timeElement.textContent = localized(
        `${hours}小时 ${remainingMinutes}分`,
        `${hours}h ${remainingMinutes}m`,
      );
    }
  };

  const updateActivityDate = () => {
    const label = simulator.querySelector<HTMLElement>("[data-sim-activity-date]");
    if (!label) return;

    if (activityDayOffset === 0) {
      label.textContent = localized("今天", "Today");
    } else if (activityDayOffset === -1) {
      label.textContent = localized("昨天", "Yesterday");
    } else {
      const date = new Date();
      date.setDate(date.getDate() + activityDayOffset);
      label.textContent = new Intl.DateTimeFormat(
        currentLanguage() === "en" ? "en-US" : "zh-CN",
        { month: "short", day: "numeric" },
      ).format(date);
    }

    simulator.querySelectorAll<HTMLButtonElement>("[data-sim-activity-day]").forEach((button) => {
      const direction = Number(button.dataset.simActivityDay ?? 0);
      button.disabled = direction > 0 && activityDayOffset === 0;
    });
    updateActivityStats();
  };

  const renderCalendar = () => {
    const target = new Date();
    target.setDate(1);
    target.setMonth(target.getMonth() + calendarMonthOffset);
    const year = target.getFullYear();
    const month = target.getMonth();
    const mondayFirstOffset = (new Date(year, month, 1).getDay() + 6) % 7;
    const today = new Date();
    const eventDays = new Set([3, 8, 12, 18, 24]);

    const titleZh = simulator.querySelector<HTMLElement>("[data-sim-calendar-title-zh]");
    const titleEn = simulator.querySelector<HTMLElement>("[data-sim-calendar-title-en]");
    if (titleZh) {
      titleZh.textContent = new Intl.DateTimeFormat("zh-CN", {
        year: "numeric",
        month: "long",
      }).format(target);
    }
    if (titleEn) {
      titleEn.textContent = new Intl.DateTimeFormat("en-US", {
        year: "numeric",
        month: "long",
      }).format(target);
    }

    simulator.querySelectorAll<HTMLButtonElement>("[data-sim-calendar-cell]").forEach((cell, index) => {
      const date = new Date(year, month, index - mondayFirstOffset + 1);
      const day = date.getDate();
      const isDisplayedMonth = date.getMonth() === month;
      const isToday = date.toDateString() === today.toDateString();
      const number = cell.querySelector<HTMLElement>("b");
      const subtitle = cell.querySelector<HTMLElement>("small");

      cell.disabled = false;
      cell.classList.remove("is-empty");
      cell.classList.toggle("is-outside", !isDisplayedMonth);
      cell.classList.toggle("is-today", isToday);
      cell.classList.toggle("has-events", isDisplayedMonth && eventDays.has(day));
      cell.classList.remove("is-selected");
      cell.dataset.simCalendarDay = String(day);
      if (number) number.textContent = String(day);
      if (subtitle) {
        subtitle.textContent = isToday
          ? localized("今天", "Today")
          : localized(
            lunarDayLabels[(day + 8) % lunarDayLabels.length],
            `D${((day + 14) % 30) + 1}`,
          );
      }
      cell.setAttribute(
        "aria-label",
        new Intl.DateTimeFormat(
          currentLanguage() === "en" ? "en-US" : "zh-CN",
          { year: "numeric", month: "long", day: "numeric" },
        ).format(date),
      );
    });
  };

  const updateActionLabels = () => {
    simulator.querySelectorAll<HTMLButtonElement>("[data-sim-action]").forEach((button) => {
      if (button.dataset.simBusy === "true") return;
      button.textContent = currentLanguage() === "en"
        ? button.dataset.actionEn ?? "Run"
        : button.dataset.actionZh ?? "操作";
    });
  };

  const synchronizeAppearance = () => {
    const appearanceToggle = simulator.querySelector<HTMLButtonElement>('[data-sim-setting="appearance"]');
    const isDark = root.dataset.theme === "dark";
    simulator.dataset.previewTheme = isDark ? "dark" : "light";
    appearanceToggle?.setAttribute("aria-checked", String(isDark));
    appearanceToggle?.classList.toggle("is-on", isDark);
  };

  const updateSimulatedData = () => {
    if (document.hidden) return;

    cpu = clamp(cpu + randomBetween(-7, 8), 12, 68);
    gpu = clamp(gpu + randomBetween(-6, 7), 7, 54);
    memory = clamp(memory + randomBetween(-1.8, 1.8), 64, 83);
    battery = clamp(battery - randomBetween(0, 0.015), 78, 84);

    updateMetric("cpu", cpu);
    updateMetric("gpu", gpu);
    updateMetric("memory", memory);
    updateMetric("battery", battery);

    const cpuCard = simulator.querySelector<HTMLElement>('[data-sim-metric="cpu"]');
    const gpuCard = simulator.querySelector<HTMLElement>('[data-sim-metric="gpu"]');
    const cpuTemp = cpuCard?.querySelector<HTMLElement>("[data-sim-temp]");
    const gpuTemp = gpuCard?.querySelector<HTMLElement>("[data-sim-temp]");
    if (cpuTemp) cpuTemp.textContent = `${Math.round(46 + cpu * 0.22)}°C`;
    if (gpuTemp) gpuTemp.textContent = `${Math.round(43 + gpu * 0.21)}°C`;

    const cpuFootnote = cpuCard?.querySelector<HTMLElement>("[data-sim-footnote]");
    const gpuFootnote = gpuCard?.querySelector<HTMLElement>("[data-sim-footnote]");
    if (cpuFootnote) cpuFootnote.textContent = `${(1.2 + cpu * 0.067).toFixed(1)} W`;
    if (gpuFootnote) gpuFootnote.textContent = `${(0.5 + gpu * 0.046).toFixed(1)} W`;

    const network = simulator.querySelector<HTMLElement>('[data-sim-metric="network"]');
    const download = randomBetween(1.8, 8.6);
    const upload = randomBetween(0.3, 2.4);
    const networkValue = network?.querySelector<HTMLElement>("[data-sim-value]");
    const downloadValue = network?.querySelector<HTMLElement>("[data-sim-down]");
    const uploadValue = network?.querySelector<HTMLElement>("[data-sim-up]");
    if (networkValue) networkValue.textContent = (download + upload).toFixed(1);
    if (downloadValue) downloadValue.textContent = download.toFixed(1);
    if (uploadValue) uploadValue.textContent = upload.toFixed(1);

    const disk = simulator.querySelector<HTMLElement>('[data-sim-metric="disk"]');
    const diskAvailable = clamp(41 + randomBetween(-0.4, 0.4), 40.4, 41.6);
    const diskValue = disk?.querySelector<HTMLElement>("[data-sim-value]");
    const diskCapacity = disk?.querySelector<HTMLElement>("[data-sim-capacity]");
    if (diskValue) diskValue.textContent = diskAvailable.toFixed(1);
    if (diskCapacity) diskCapacity.style.width = `${(100 - diskAvailable / 228 * 100).toFixed(1)}%`;

    const memoryUsed = simulator.querySelector<HTMLElement>('[data-sim-metric="memory"] [data-sim-used]');
    if (memoryUsed) memoryUsed.textContent = (16 * memory / 100).toFixed(1);

    const batteryCapacity = simulator.querySelector<HTMLElement>('[data-sim-metric="battery"] [data-sim-capacity]');
    const deviceLevel = simulator.querySelector<HTMLElement>('[data-sim-device-level="mac"]');
    const deviceBar = simulator.querySelector<HTMLElement>('[data-sim-device-bar="mac"]');
    if (batteryCapacity) batteryCapacity.style.width = `${battery.toFixed(1)}%`;
    if (deviceLevel) deviceLevel.textContent = `${Math.round(battery)}%`;
    if (deviceBar) deviceBar.style.width = `${battery.toFixed(1)}%`;

    simulator.querySelectorAll<HTMLElement>("[data-sim-process-cpu]").forEach((process, index) => {
      const factor = [0.16, 0.12, 0.07][index] ?? 0.05;
      process.textContent = `${Math.max(0.8, cpu * factor + randomBetween(-1.2, 1.2)).toFixed(1)}%`;
    });

    if (activityDayOffset === 0) updateActivityStats();
  };

  for (const tab of tabs) {
    tab.addEventListener("click", () => {
      const selectedView = tab.dataset.simTab;
      if (selectedView) selectView(selectedView);
    });
  }

  simulator.querySelectorAll<HTMLButtonElement>("[data-sim-disclosure]").forEach((button) => {
    button.addEventListener("click", () => {
      const item = button.closest<HTMLElement>(".sim-feature-item");
      const detail = item?.querySelector<HTMLElement>("[data-sim-disclosure-detail]");
      if (!item || !detail) return;

      const shouldOpen = button.getAttribute("aria-expanded") !== "true";
      simulator.querySelectorAll<HTMLButtonElement>("[data-sim-disclosure]").forEach((otherButton) => {
        const otherItem = otherButton.closest<HTMLElement>(".sim-feature-item");
        const otherDetail = otherItem?.querySelector<HTMLElement>("[data-sim-disclosure-detail]");
        const isCurrent = otherButton === button && shouldOpen;
        otherButton.setAttribute("aria-expanded", String(isCurrent));
        otherItem?.classList.toggle("is-expanded", isCurrent);
        if (otherDetail) otherDetail.hidden = !isCurrent;
      });
    });
  });

  simulator.querySelectorAll<HTMLButtonElement>("[data-sim-setting]").forEach((button) => {
    button.addEventListener("click", () => {
      const isOn = button.getAttribute("aria-checked") !== "true";
      button.setAttribute("aria-checked", String(isOn));
      button.classList.toggle("is-on", isOn);

      if (button.dataset.simSetting === "appearance") {
        const theme = isOn ? "dark" : "light";
        root.dataset.theme = theme;
        localStorage.setItem("mactools-theme", theme);
        synchronizeAppearance();
      }
    });
  });

  simulator.querySelectorAll<HTMLInputElement>("[data-sim-range]").forEach((range) => {
    range.addEventListener("input", () => {
      const value = range.closest(".sim-feature-detail")?.querySelector<HTMLElement>("[data-sim-range-value]");
      if (value) value.textContent = `${range.value}${range.dataset.simRangeUnit ?? ""}`;

    });
  });

  simulator.querySelectorAll<HTMLButtonElement>("[data-sim-segment]").forEach((button) => {
    button.addEventListener("click", () => {
      button.closest(".sim-detail-segments")?.querySelectorAll<HTMLButtonElement>("[data-sim-segment]")
        .forEach((option) => {
          const isSelected = option === button;
          option.classList.toggle("is-selected", isSelected);
          option.setAttribute("aria-pressed", String(isSelected));
        });
    });
  });

  simulator.querySelectorAll<HTMLButtonElement>("[data-sim-check]").forEach((button) => {
    button.addEventListener("click", () => {
      const isChecked = button.getAttribute("aria-checked") !== "true";
      button.setAttribute("aria-checked", String(isChecked));
    });
  });

  simulator.querySelectorAll<HTMLButtonElement>("[data-sim-action]").forEach((button) => {
    button.addEventListener("click", () => {
      const pluginName = currentLanguage() === "en"
        ? button.dataset.pluginNameEn ?? "Plugin"
        : button.dataset.pluginNameZh ?? "插件";
      button.dataset.simBusy = "true";
      button.disabled = true;
      button.textContent = localized("处理中", "Working");

      window.setTimeout(() => {
        button.textContent = localized("完成", "Done");
        showToast(localized(`${pluginName} · 已完成（模拟）`, `${pluginName} · completed (simulation)`));

        window.setTimeout(() => {
          button.dataset.simBusy = "false";
          button.disabled = false;
          updateActionLabels();
        }, 900);
      }, 620);
    });
  });

  simulator.querySelectorAll<HTMLButtonElement>("[data-sim-activity-day]").forEach((button) => {
    button.addEventListener("click", () => {
      const direction = Number(button.dataset.simActivityDay ?? 0);
      activityDayOffset = Math.min(0, Math.max(-14, activityDayOffset + direction));
      updateActivityDate();
    });
  });

  simulator.querySelectorAll<HTMLButtonElement>("[data-sim-calendar-nav]").forEach((button) => {
    button.addEventListener("click", () => {
      const action = button.dataset.simCalendarNav;
      if (action === "previous") calendarMonthOffset -= 1;
      if (action === "next") calendarMonthOffset += 1;
      if (action === "today") calendarMonthOffset = 0;
      renderCalendar();
    });
  });

  simulator.querySelectorAll<HTMLButtonElement>("[data-sim-calendar-cell]").forEach((button) => {
    button.addEventListener("click", () => {
      if (!button.dataset.simCalendarDay) return;
      simulator.querySelectorAll("[data-sim-calendar-cell]").forEach((cell) => {
        cell.classList.toggle("is-selected", cell === button);
      });
      showToast(localized(
        `${button.dataset.simCalendarDay} 日 · 日程预览`,
        `Day ${button.dataset.simCalendarDay} · event preview`,
      ));
    });
  });

  simulator.querySelectorAll<HTMLButtonElement>("[data-sim-toolbar-action]").forEach((button) => {
    button.addEventListener("click", () => {
      if (button.dataset.simToolbarAction === "quit") {
        showToast(localized("退出操作仅为模拟", "Quit action is simulated"));
      }
    });
  });

  const rootObserver = new MutationObserver((records) => {
    updateLocalizedAttributes();
    updateActionLabels();
    updateActivityDate();
    renderCalendar();

    if (records.some((record) => record.attributeName === "data-theme")) {
      synchronizeAppearance();
    }
  });
  rootObserver.observe(root, { attributes: true, attributeFilter: ["data-lang", "data-theme"] });

  synchronizeAppearance();
  updateLocalizedAttributes();
  updateActionLabels();
  updateActivityDate();
  renderCalendar();
  updateSimulatedData();
  window.setInterval(updateSimulatedData, 1_650);
});
