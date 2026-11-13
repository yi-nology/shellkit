import { viteBundler } from '@vuepress/bundler-vite'
import { defaultTheme } from '@vuepress/theme-default'
import { searchPlugin } from '@vuepress/plugin-search'
import { defineUserConfig } from 'vuepress'
import { fileURLToPath } from 'node:url'

const REPO = 'https://github.com/yi-nology/shellkit'

// 站点对外地址：llms.txt 这类「给 AI 直读」的入口要用绝对地址，
// 相对地址在站点外（比如被别的工具 fetch）时是坏的。
const SITE_BASE = 'https://yi-nology.github.io/shellkit'

// 与 tools/shdoc.sh 的 MODULES 同序：读者按「先有什么、后有什么」看
const MODULES = [
  'error', 'i18n', 'log', 'str', 'validate', 'fs', 'os', 'trap', 'run',
  'retry', 'lock', 'net', 'config', 'prompt', 'cli',
]

const zhGuideSidebar = [
  { text: '开始', collapsible: true, children: ['/guide/index.md', '/guide/installation.md', '/guide/quickstart.md'] },
  { text: '核心概念', collapsible: true, children: ['/guide/conventions.md', '/guide/bash32.md', '/guide/modules.md'] },
  { text: '常见任务', collapsible: true, children: ['/guide/cookbook.md', '/guide/cli.md', '/guide/json.md', '/guide/security.md', '/guide/i18n.md', '/guide/testing.md', '/guide/ai.md'] },
  { text: '进阶', collapsible: true, children: ['/guide/examples.md', '/guide/man.md', '/guide/migrating.md', '/guide/releasing.md', '/guide/contributing.md'] },
  { text: '排错', collapsible: true, children: ['/guide/troubleshooting.md', '/guide/faq.md'] },
]

const enGuideSidebar = [
  { text: 'Getting started', collapsible: true, children: ['/en/guide/index.md', '/en/guide/installation.md', '/en/guide/quickstart.md'] },
  { text: 'Core concepts', collapsible: true, children: ['/en/guide/conventions.md', '/en/guide/bash32.md', '/en/guide/modules.md'] },
  { text: 'Common tasks', collapsible: true, children: ['/en/guide/cookbook.md', '/en/guide/cli.md', '/en/guide/json.md', '/en/guide/security.md', '/en/guide/i18n.md', '/en/guide/testing.md', '/en/guide/ai.md'] },
  { text: 'Going further', collapsible: true, children: ['/en/guide/examples.md', '/en/guide/man.md', '/en/guide/migrating.md', '/en/guide/releasing.md', '/en/guide/contributing.md'] },
  { text: 'Troubleshooting', collapsible: true, children: ['/en/guide/troubleshooting.md', '/en/guide/faq.md'] },
]

const referenceChildren = (prefix: string): string[] => [
  prefix + '/reference/index.md',
  ...MODULES.map((m) => prefix + '/reference/' + m + '.md'),
]

export default defineUserConfig({
  lang: 'zh-CN',
  title: 'shellkit',
  description: '约束清晰的 Bash 库、脚手架生成器与 CLI 框架。基线 Bash 3.2+，stdout 只给数据，日志一律 stderr。',
  base: '/shellkit/',

  // 三态配色（白 / 黑 / 跟随系统）：把主题的两态 useDarkMode 整体换成我们的一份。
  // VuePress 的 resolveAlias 按键长降序排序，长键必然优先于主题的 '@theme' 前缀键。
  alias: {
    '@theme/useDarkMode': fileURLToPath(new URL('./useDarkMode.ts', import.meta.url)),
  },

  head: [
    ['link', { rel: 'icon', href: '/shellkit/favicon.svg', type: 'image/svg+xml' }],
    ['meta', { name: 'theme-color', content: '#0d1117' }],
    ['meta', { name: 'author', content: 'yi-nology' }],
    ['meta', { property: 'og:type', content: 'website' }],
    ['meta', { property: 'og:site_name', content: 'shellkit' }],
    // og:image 用绝对地址：分享到 IM/社交平台时抓取方不在站点内，相对路径是坏的。
    // 中英两站共用一张（图里是品牌名 + 代码 token，没有会过期的散文）。
    ['meta', { property: 'og:title', content: 'shellkit — 写运维 shell 的起点' }],
    ['meta', { property: 'og:description', content: '约束清晰的 Bash 库、脚手架生成器与 CLI 框架。基线 Bash 3.2+，stdout 只给数据，日志一律 stderr。' }],
    ['meta', { property: 'og:image', content: SITE_BASE + '/og.png' }],
    ['meta', { name: 'twitter:card', content: 'summary_large_image' }],
    ['meta', { name: 'twitter:title', content: 'shellkit — 写运维 shell 的起点' }],
    ['meta', { name: 'twitter:image', content: SITE_BASE + '/og.png' }],
    // 首帧前定 data-theme：主题按 [data-theme] 上色，不定就会闪一下错误底色。
    // 逻辑与 .vuepress/useDarkMode.ts 同源：三态 + 旧键 vuepress-color-scheme 迁移。
    [
      'script',
      {
        innerHTML:
          "(function(){try{var m=localStorage.getItem('sk-color-mode');" +
          "if(m!=='light'&&m!=='dark'&&m!=='auto'){m=localStorage.getItem('vuepress-color-scheme')}" +
          "if(m!=='light'&&m!=='dark'&&m!=='auto'){m='auto'}" +
          "var dark=m==='auto'?window.matchMedia('(prefers-color-scheme: dark)').matches:m==='dark';" +
          "document.documentElement.setAttribute('data-theme',dark?'dark':'light')}" +
          "catch(e){document.documentElement.setAttribute('data-theme','dark')}})()",
      },
    ],
  ],

  locales: {
    '/': {
      lang: 'zh-CN',
      title: 'shellkit',
      description: '写运维 shell 的起点：Bash 库、脚手架生成器、CLI 框架。',
    },
    '/en/': {
      lang: 'en-US',
      title: 'shellkit',
      description: 'A Bash library, project generator and CLI framework with explicit constraints.',
    },
  },

  bundler: viteBundler(),

  theme: defaultTheme({
    logo: '/logo.svg',
    // 内置两态开关藏起来：导航栏用我们自己的三段选择器（navbar-after 挂载）。
    // 配色默认值改由 useDarkMode.ts 决定 —— 首次访问跟随系统。
    colorMode: 'dark',
    colorModeSwitch: false,
    lastUpdated: true,
    contributors: false,
    editLink: false,
    sidebarDepth: 2,
    docsRepo: 'yi-nology/shellkit',
    docsBranch: 'main',
    docsDir: 'site',

    // 页脚挂一处 llms.txt 入口：给 AI 直读的人不用先知道站点的结构，
    // 一个文件就是整张地图（导航栏里也有一处）。
    footer: {
      message: {
        text: '给 AI 直读：llms.txt',
        link: SITE_BASE + '/llms.txt',
      },
      copyright: 'MIT Licensed. Copyright © 2026 shellkit contributors.',
    },

    // Prism 默认只有一套 nord 深色配色，浅色模式下代码正文会变成近白色、
    // 压在浅底上等于隐形。这里浅色用 coldark-cold、深色用 nord。
    themePlugins: {
      prismjs: {
        themes: {
          light: 'coldark-cold',
          dark: 'nord',
        },
      },
    },

    locales: {
      '/': {
        selectLanguageName: '简体中文',
        selectLanguageText: '语言',
        selectLanguageAriaLabel: '选择语言',
        notFound: ['页面不存在', '这一页要么改名了，要么还没写。'],
        backToHome: '回到首页',
        lastUpdatedText: '最后更新',
        navbar: [
          { text: '指南', link: '/guide/index.md' },
          { text: 'API 参考', link: '/reference/index.md' },
          { text: '示例', link: '/guide/examples.md' },
          { text: '发布产物', link: REPO + '/releases' },
          { text: 'llms.txt', link: SITE_BASE + '/llms.txt' },
          { text: 'GitHub', link: REPO },
        ],
        sidebar: {
          '/guide/': zhGuideSidebar,
          '/reference/': [{ text: 'API 参考', collapsible: false, children: referenceChildren('') }],
        },
      },
      '/en/': {
        selectLanguageName: 'English',
        selectLanguageText: 'Languages',
        selectLanguageAriaLabel: 'Select language',
        notFound: ['Page not found', 'This page was renamed or has not been written yet.'],
        backToHome: 'Back to home',
        lastUpdatedText: 'Last updated',
        navbar: [
          { text: 'Guide', link: '/en/guide/index.md' },
          { text: 'API reference', link: '/en/reference/index.md' },
          { text: 'Examples', link: '/en/guide/examples.md' },
          { text: 'Releases', link: REPO + '/releases' },
          { text: 'llms.txt', link: SITE_BASE + '/llms.txt' },
          { text: 'GitHub', link: REPO },
        ],
        sidebar: {
          '/en/guide/': enGuideSidebar,
          '/en/reference/': [{ text: 'API reference', collapsible: false, children: referenceChildren('/en') }],
        },
      },
    },
  }),

  plugins: [
    searchPlugin({
      locales: {
        '/': { placeholder: '搜索文档' },
        '/en/': { placeholder: 'Search docs' },
      },
    }),
  ],
})
