globalThis.Flux6Site = (() => {
  'use strict';

  const REPO = 'https://github.com/study-233/flux6';
  const FIRST_PAGE = 6;
  const MAX_STAGGER = 16;
  const TYPE_BY_TITLE = {
    'Breaking Changes': 'breaking',
    Features: 'feat',
    'Bug Fixes': 'fix',
    Performance: 'perf',
    Reverts: 'revert',
  };
  const TYPE_KEYS = { breaking: 'typeBreaking', feat: 'typeFeat', fix: 'typeFix', perf: 'typePerf', revert: 'typeRevert' };
  const ICON_EXTERNAL =
    '<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><path d="M6 3.5h6.5V10M12.25 3.75 4 12" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  // Product copy and UI translations adapted for Flux6.
  const STRINGS = {
    en: {
      pageTitle: "Flux6 — A lighter way to connect",
      pageDescription: "Flux6 is an open-source IPv6 client for campus networks, available for Apple Silicon Macs and ARM64 Android devices. Download, install and connect.",
      skip: "Skip to downloads",
      navDownload: "Download",
      navChangelog: "Changelog",
      langToggle: "中文",
      langLabel: "切换到中文",
      themeLabel: "Toggle dark mode",
      heroFor: "for",
      reelLabel: "Switch platform",
      heroLede: "A lighter way to connect to campus IPv6. Smart node selection, WARP egress, and a clear view of your connection. Open source and ad-free.",
      heroOther: "Other platforms",
      heroReleaseLoading: "Latest release",
      heroRelease: (v) => `${v} is out · See what’s new`,
      ctaDownload: (p) => `Download for ${p}`,
      ctaChoose: "Choose a download",
      ctaIos: "Available for macOS and Android. Choose a build for a supported device below.",
      previewAlt: "Flux6 macOS dashboard, currently distributed as Flux6",
      fact1Title: "Campus IPv6",
      fact1: "Built for campus networks with IPv6 connectivity.",
      fact2Title: "Smart selection",
      fact2: "Check node latency and automatically select a connection.",
      fact3Title: "WARP egress",
      fact3: "Manage your connection and routing in one place.",
      fact4Title: "Open source",
      fact4: "Read the code, follow changes, and make it better.",
      dlTitle: "Download",
      dlMeta: (v, d) => `Version ${v} · Released ${d}`,
      dlLead: "Available for Apple Silicon Macs and ARM64 Android devices. Choose your platform below.",
      dlAll: "All releases on GitHub",
      dlError: "Release details could not be loaded. Download from GitHub Releases instead.",
      platformLabel: "Platform",
      archLabel: "Architecture",
      recommended: "Recommended",
      copied: "Copied",
      copy: "Copy",
      copySha: (name) => `Copy the SHA-256 of ${name}`,
      hintAndroid: "ARM64 devices · Android 7.0 or later",
      hintMacos: "Apple Silicon · macOS 14 or later. No Intel build.",
      noteAndroidArm64: "Install the APK on an ARM64 phone or tablet",
      noteMacArm: "Open the DMG and drag Flux6 into Applications",
      tipBrewTitle: "Homebrew",
      tipBrew: "Install from your terminal and update with Homebrew.",
      clTitle: "Changelog",
      clMeta: (n, d) => `${n} releases since ${d}`,
      clSearch: "Search changes or versions",
      clLatest: "Latest",
      clMore: (n) => `Show earlier releases (${n} more)`,
      clResults: (e, v) => `${e} ${e === 1 ? 'change' : 'changes'} in ${v} ${v === 1 ? 'release' : 'releases'}`,
      clNone: (q) => `Nothing matches “${q}”.`,
      clClear: "Clear",
      clEmpty: "Internal improvements only.",
      clError: "The changelog could not be loaded.",
      clErrorLink: "Read the release notes on GitHub",
      clOnGithub: "GitHub",
      clOnGithubLabel: (v) => `Release ${v} on GitHub`,
      typeBreaking: "Breaking changes",
      typeFeat: "Features",
      typeFix: "Fixes",
      typePerf: "Performance",
      typeRevert: "Reverts",
      footLicense: "Open-source software for campus IPv6.",
      footUpdated: "Website adapted from FlClash.",
      footReleases: "Releases",
      footTelegram: "Feedback",
      stars: (n) => `${n} stars on GitHub`,
      mobileAlt: "Flux6 Android dashboard, currently distributed as Flux6",
      releaseNote: "Flux6 0.1.1 adds in-app updates for macOS and Android.",
      noteMacZip: "Application archive for manual installation",
      macZip: "Application archive",
      tipSetupTitle: "Getting started",
      tipSetup: "Connect to an IPv6-capable Wi-Fi network, complete the setup guide, then connect in the app.",
      siteLicense: "Website license",
      copyFailed: "Copy failed. Select and copy the text manually.",
    },
    zh: {
      pageTitle: "Flux6 — 让校园连接更轻盈",
      pageDescription: "Flux6 是面向校园网络的开源 IPv6 客户端，支持 Apple Silicon Mac 与 ARM64 Android 设备，提供节点选择、WARP 出口与连接管理。",
      skip: "跳到下载",
      navDownload: "下载",
      navChangelog: "更新日志",
      langToggle: "EN",
      langLabel: "Switch to English",
      themeLabel: "切换深色模式",
      heroFor: "适用于",
      reelLabel: "切换平台",
      heroLede: "让校园 IPv6 连接更轻盈。自动选择节点，管理 WARP 出口，连接状态一目了然。开源，无广告。",
      heroOther: "其他平台",
      heroReleaseLoading: "最新版本",
      heroRelease: (v) => `${v} 已发布 · 查看更新`,
      ctaDownload: (p) => `下载 ${p} 版`,
      ctaChoose: "选择下载版本",
      ctaIos: "目前提供 macOS 与 Android 版本，请在下方为支持的设备选择安装包。",
      previewAlt: "Flux6 macOS 仪表盘，当前安装包名为 Flux6",
      fact1Title: "校园 IPv6",
      fact1: "为支持 IPv6 的校园网络而设计。",
      fact2Title: "自动选点",
      fact2: "查看节点延迟，自动选择合适的连接。",
      fact3Title: "WARP 出口",
      fact3: "连接状态与分流模式，集中管理。",
      fact4Title: "开源透明",
      fact4: "源码公开，改进可追溯，欢迎参与。",
      dlTitle: "下载",
      dlMeta: (v, d) => `版本 ${v} · ${d}发布`,
      dlLead: "支持 Apple Silicon Mac 与 ARM64 Android 设备，在下方选择你的平台。",
      dlAll: "在 GitHub 查看全部版本",
      dlError: "未能读取版本信息，请前往 GitHub Releases 下载。",
      platformLabel: "平台",
      archLabel: "架构",
      recommended: "推荐",
      copied: "已复制",
      copy: "复制",
      copySha: (name) => `复制 ${name} 的 SHA-256`,
      hintAndroid: "ARM64 设备 · Android 7.0 及以上",
      hintMacos: "Apple Silicon · macOS 14 及以上，暂不提供 Intel 版本。",
      noteAndroidArm64: "在 ARM64 手机或平板上安装 APK",
      noteMacArm: "打开 DMG，将 Flux6 拖入「应用程序」",
      tipBrewTitle: "Homebrew",
      tipBrew: "通过终端安装，之后用 brew 升级。",
      clTitle: "更新日志",
      clMeta: (n, d) => `自 ${d}以来共 ${n} 个版本`,
      clSearch: "搜索更新内容或版本",
      clLatest: "最新",
      clMore: (n) => `显示更早的版本（还有 ${n} 个）`,
      clResults: (e, v) => `${v} 个版本中有 ${e} 条匹配`,
      clNone: (q) => `没有与「${q}」相关的更新。`,
      clClear: "清除",
      clEmpty: "仅内部改进。",
      clError: "未能加载更新日志。",
      clErrorLink: "在 GitHub 查看发行说明",
      clOnGithub: "GitHub",
      clOnGithubLabel: (v) => `在 GitHub 查看 ${v} 发布页`,
      typeBreaking: "不兼容变更",
      typeFeat: "新功能",
      typeFix: "问题修复",
      typePerf: "性能",
      typeRevert: "回退",
      footLicense: "面向校园 IPv6 的开源客户端。",
      footUpdated: "网页改编自 FlClash。",
      footReleases: "发布页",
      footTelegram: "反馈问题",
      stars: (n) => `GitHub 上有 ${n} 个星标`,
      mobileAlt: "Flux6 Android 仪表盘，当前安装包名为 Flux6",
      releaseNote: "Flux6 0.1.1 为 macOS 和 Android 加入应用内更新。",
      noteMacZip: "适用于手动安装的应用压缩包",
      macZip: "应用压缩包",
      tipSetupTitle: "开始使用",
      tipSetup: "连接支持 IPv6 的 Wi-Fi，按首次引导完成配置，再在应用内连接。",
      siteLicense: "网页许可",
      copyFailed: "复制失败，请手动选择并复制文本。",
    },
  };

  function parseChangelog(markdown) {
    const versions = [];
    let version = null;
    let group = null;
    let entry = null;
    for (const raw of markdown.split(/\r?\n/)) {
      const line = raw.trimEnd();
      let match = line.match(/^## (v?\d[^\s(]*)(?: \((\d{4}-\d{2}-\d{2})\))?$/);
      if (match) {
        version = { tag: match[1], version: match[1].replace(/^v/, ''), date: match[2] || '', groups: [], empty: false };
        versions.push(version);
        group = null;
        entry = null;
        continue;
      }
      if (!version) continue;
      match = line.match(/^\*\*(.+)\*\*$/);
      if (match) {
        group = { type: TYPE_BY_TITLE[match[1]] || 'other', title: match[1], entries: [] };
        version.groups.push(group);
        entry = null;
        continue;
      }
      match = line.match(/^[-*] (.+)$/);
      if (match) {
        if (!group) {
          group = { type: null, title: '', entries: [] };
          version.groups.push(group);
        }
        entry = parseEntry(match[1]);
        group.entries.push(entry);
        continue;
      }
      if (entry && /^\s+\S/.test(raw)) {
        entry.text += ` ${raw.trim()}`;
        continue;
      }
      if (line === 'Internal improvements only.') version.empty = true;
    }
    return versions;
  }

  function parseEntry(source) {
    let text = source;
    let scope = null;
    let id = null;
    const scoped = text.match(/^\*\*([^*]+)\*\* (.+)$/);
    if (scoped) {
      scope = scoped[1];
      text = scoped[2];
    }
    const hashed = text.match(/^(.*) \(([0-9a-f]{7,40})\)$/);
    if (hashed) {
      text = hashed[1];
      id = hashed[2];
    }
    return { scope, text, id };
  }

  function translate(lang, key, ...args) {
    const value = STRINGS[lang][key] ?? STRINGS.en[key] ?? key;
    return typeof value === 'function' ? value(...args) : value;
  }

  function formatDate(iso, lang) {
    if (!iso) return '';
    return new Intl.DateTimeFormat(lang === 'zh' ? 'zh-CN' : 'en', {
      year: 'numeric',
      month: lang === 'zh' ? 'long' : 'short',
      day: 'numeric',
      timeZone: 'UTC',
    }).format(new Date(`${iso}T00:00:00Z`));
  }

  function changelogMeta(versions, lang) {
    const oldest = versions.filter((version) => version.date).pop();
    return oldest ? translate(lang, 'clMeta', versions.length, formatDate(oldest.date, lang)) : '';
  }

  function escapeHtml(text) {
    return String(text).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
  }

  function highlight(text, query) {
    if (!query) return escapeHtml(text);
    const lower = text.toLowerCase();
    let html = '';
    let from = 0;
    for (let at = lower.indexOf(query); at !== -1; at = lower.indexOf(query, from)) {
      html += `${escapeHtml(text.slice(from, at))}<mark>${escapeHtml(text.slice(at, at + query.length))}</mark>`;
      from = at + query.length;
    }
    return html + escapeHtml(text.slice(from));
  }

  function releaseHtml(version, groups, { lang, query, isLatest, ago }) {
    const t = (key, ...args) => translate(lang, key, ...args);
    const tag = escapeHtml(version.tag);
    let row = 0;
    const order = () => ` style="--i:${Math.min(row++, MAX_STAGGER)}"`;
    const sections = groups.map((group) => {
      const title = group.type ? (TYPE_KEYS[group.type] ? t(TYPE_KEYS[group.type]) : group.title) : '';
      const heading = title
        ? `<h3 class="group-title"${order()}><span class="mark" aria-hidden="true"></span>${escapeHtml(title)}</h3>`
        : '';
      const entries = group.entries.map((entry) => {
        const scope = entry.scope ? `<span class="scope">${highlight(entry.scope, query)}</span>` : '';
        const hash = entry.id ? `<a class="hash" href="${REPO}/commit/${entry.id}">${entry.id.slice(0, 7)}</a>` : '';
        return `<li class="entry"${order()}><span class="entry-text">${scope}${highlight(entry.text, query)}</span>${hash}</li>`;
      });
      return (
        `<section class="${group.type ? 'group' : 'group plain'}" data-type="${escapeHtml(group.type || 'plain')}">` +
        `${heading}<ul class="entries">${entries.join('')}</ul></section>`
      );
    });
    const empty = version.empty && !groups.length ? `<p class="empty">${escapeHtml(t('clEmpty'))}</p>` : '';
    const title = ago ? ` title="${escapeHtml(ago(version.date))}"` : '';
    const date = version.date
      ? `<span class="when"><time datetime="${version.date}"${title}>${formatDate(version.date, lang)}</time></span>`
      : '';
    return (
      `<article class="release" id="${tag}"><header class="release-head"><div class="ver-row">` +
      `<a class="ver" href="#${tag}">${highlight(version.version, query)}</a>` +
      (isLatest ? `<span class="latest">${escapeHtml(t('clLatest'))}</span>` : '') +
      `</div>${date}<span class="when"><a href="${REPO}/releases/tag/${tag}" ` +
      `aria-label="${escapeHtml(t('clOnGithubLabel', version.tag))}">${escapeHtml(t('clOnGithub'))} ${ICON_EXTERNAL}</a>` +
      `</span></header><div class="release-body">${empty}${sections.join('')}</div></article>`
    );
  }

  function timelineHtml(items, { lang, query = '', latestTag, ago, year = null }) {
    let html = '';
    for (const { version, groups } of items) {
      const releaseYear = version.date.slice(0, 4);
      if (releaseYear && releaseYear !== year) {
        html += `<div class="year">${releaseYear}</div>`;
        year = releaseYear;
      }
      html += releaseHtml(version, groups, { lang, query, isLatest: version.tag === latestTag, ago });
    }
    return { html, year };
  }

  return { REPO, FIRST_PAGE, STRINGS, parseChangelog, translate, formatDate, changelogMeta, escapeHtml, timelineHtml };
})();

