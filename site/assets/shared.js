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
      pageTitle: "Flux6 · WARP for macOS, Android and Windows",
      pageDescription: "An open-source WARP client with MASQUE for macOS, Android and Windows. Set up WARP on first launch and track upload and download usage.",
      skip: "Skip to downloads",
      navDownload: "Download",
      navChangelog: "Changelog",
      langToggle: "中文",
      langLabel: "切换到中文",
      themeLabel: "Toggle dark mode",
      heroFor: "for",
      reelLabel: "Switch platform",
      heroLede: "Set up WARP on first launch. Connect over IPv6 and see how much data you upload and download on macOS, Android and Windows.",
      heroOther: "Other platforms",
      heroReleaseLoading: "Latest release",
      heroRelease: (v) => `${v} is out · See what’s new`,
      ctaDownload: (p) => `Download for ${p}`,
      ctaChoose: "Choose a download",
      ctaIos: "Available for macOS, Android and Windows. Choose a build for a supported device below.",
      previewAlt: "Flux6 desktop dashboard with monthly traffic usage, using example data",
      fact1Title: "WARP setup",
      fact1: "Approve device registration to generate your configuration.",
      fact2Title: "IPv6 networks",
      fact2: "Connect on Wi-Fi or cellular with an IPv6 connection.",
      fact3Title: "Traffic charts",
      fact3: "Compare uploads and downloads for this session, month or all time.",
      fact4Title: "Local proxy",
      fact4: "Point HTTP or SOCKS apps to 127.0.0.1:17890.",
      dlTitle: "Download",
      dlMeta: (v, d) => `Version ${v} · Released ${d}`,
      dlLead: "Available for Apple Silicon Macs, ARM64 Android devices and x64 Windows PCs. Choose your platform below.",
      dlAll: "All releases on GitHub",
      dlError: "Release details could not be loaded. Download from GitHub Releases instead.",
      platformLabel: "Platform",
      recommended: "Recommended",
      copied: "Copied",
      copy: "Copy",
      copySha: (name) => `Copy the SHA-256 of ${name}`,
      hintAndroid: "ARM64 devices · Android 7.0 or later",
      hintMacos: "Apple Silicon · macOS 14 or later",
      noteAndroidArm64: "Install the APK on an ARM64 phone or tablet",
      noteMacArm: "Open the DMG and drag Flux6 into Applications. This build has not been notarized by Apple.",
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
      footLicense: "An open-source WARP client for IPv6 networks.",
      footUpdated: "Website adapted from FlClash.",
      footReleases: "Releases",
      footTelegram: "Feedback",
      stars: (n) => `${n} stars on GitHub`,
      mobileAlt: "Flux6 Android dashboard with upload and download shares, using example data",
      releaseNote: "Upgrading from 0.1.x? Disconnect and quit first. On first launch, 0.2.0 clears old settings, credentials and usage history. On macOS, install the new DMG manually.",
      noteMacZip: "Application archive for manual installation",
      macZip: "Application archive",
      tipSetupTitle: "Getting started",
      tipSetup: "Open Flux6 and approve device registration. When the WARP profile is ready, select Connect.",
      siteLicense: "Website license",
      copyFailed: "Copy failed. Select and copy the text manually.",
      hintWindows: "Windows · x64",
      windowsSetup: "x64 installer",
      windowsPortable: "Portable archive",
      noteWindowsSetup: "Run the installer to install or upgrade Flux6.",
      noteWindowsPortable: "Extract the entire ZIP before launching Flux6.",
    },
    zh: {
      pageTitle: "Flux6 · macOS、Android 和 Windows 的 WARP 客户端",
      pageDescription: "Flux6 是支持 MASQUE 的开源 WARP 客户端。macOS、Android 和 Windows 均可在首次启动时配置 WARP，并查看上传和下载用量。",
      skip: "跳到下载",
      navDownload: "下载",
      navChangelog: "更新日志",
      langToggle: "EN",
      langLabel: "Switch to English",
      themeLabel: "切换深色模式",
      heroFor: "适用于",
      reelLabel: "切换平台",
      heroLede: "首次启动自动配置 WARP。在支持 IPv6 的网络上连接，打开仪表盘即可查看上传和下载用量。",
      heroOther: "其他平台",
      heroReleaseLoading: "最新版本",
      heroRelease: (v) => `${v} 已发布 · 查看更新`,
      ctaDownload: (p) => `下载 ${p} 版`,
      ctaChoose: "选择下载版本",
      ctaIos: "目前提供 macOS、Android 和 Windows 版本，请在下方为支持的设备选择安装包。",
      previewAlt: "Flux6 桌面仪表盘与本月流量统计，使用示例数据",
      fact1Title: "WARP 配置",
      fact1: "首次启动同意设备注册后，自动生成配置。",
      fact2Title: "IPv6 网络",
      fact2: "支持具有 IPv6 出口的 Wi-Fi 和移动网络。",
      fact3Title: "流量图表",
      fact3: "比较本次连接、本月和累计的上下行用量。",
      fact4Title: "本地代理",
      fact4: "HTTP 和 SOCKS 默认使用 127.0.0.1:17890。",
      dlTitle: "下载",
      dlMeta: (v, d) => `版本 ${v} · ${d}发布`,
      dlLead: "支持 Apple Silicon Mac、ARM64 Android 设备和 Windows x64，在下方选择你的平台。",
      dlAll: "在 GitHub 查看全部版本",
      dlError: "未能读取版本信息，请前往 GitHub Releases 下载。",
      platformLabel: "平台",
      recommended: "推荐",
      copied: "已复制",
      copy: "复制",
      copySha: (name) => `复制 ${name} 的 SHA-256`,
      hintAndroid: "ARM64 设备 · Android 7.0 及以上",
      hintMacos: "Apple Silicon · macOS 14 及以上",
      noteAndroidArm64: "在 ARM64 手机或平板上安装 APK",
      noteMacArm: "打开 DMG，将 Flux6 拖入「应用程序」。本版未经 Apple 公证。",
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
      footLicense: "面向 IPv6 网络的开源 WARP 客户端。",
      footUpdated: "网页改编自 FlClash。",
      footReleases: "发布页",
      footTelegram: "反馈问题",
      stars: (n) => `GitHub 上有 ${n} 个星标`,
      mobileAlt: "Flux6 Android 仪表盘与上下行占比，使用示例数据",
      releaseNote: "从 0.1.x 升级前，请先断开并退出旧版。首次启动 0.2.0 会清空旧配置、凭据和用量历史。macOS 用户请下载 DMG 覆盖安装。",
      noteMacZip: "适用于手动安装的应用压缩包",
      macZip: "应用压缩包",
      tipSetupTitle: "开始使用",
      tipSetup: "首次启动同意设备注册，等 WARP 配置就绪后点击连接。",
      siteLicense: "网页许可",
      copyFailed: "复制失败，请手动选择并复制文本。",
      hintWindows: "Windows · x64",
      windowsSetup: "x64 安装程序",
      windowsPortable: "便携压缩包",
      noteWindowsSetup: "运行安装程序以安装或升级 Flux6。",
      noteWindowsPortable: "完整解压 ZIP 后启动 Flux6。",
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

